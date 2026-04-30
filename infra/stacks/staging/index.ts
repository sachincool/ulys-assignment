/**
 * staging stack — same shape as dev, but no spot VMs (we want stable
 * canary windows), Cloud SQL HA on, BinAuthz on (so the prod admission
 * policy is exercised here first).
 *
 * Still ZONAL — single zone, single region. Multi-region is a clean upgrade.
 *
 * Costs ≈ $120-150/mo.
 */
import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";
import { Network } from "../../components/network";
import { Gke } from "../../components/gke";
import { Postgres } from "../../components/postgres";
import { Memorystore } from "../../components/memorystore";
import { Secret } from "../../components/secrets";
import { WorkloadIdentity } from "../../components/workload-identity";
import { BinAuthz } from "../../components/binauthz";

const config = new pulumi.Config();
const region = gcp.config.region ?? "us-central1";
const zone   = `${region}-a`;
const project = gcp.config.project!;

const net = new Network("ulys", { name: "ulys", region });

const ba = new BinAuthz("attestor-staging", {
  env: "staging",
  cosignPubKeyPem: config.requireSecret("cosignPubKeyPem"),
});

const gke = new Gke("ulys-gke", {
  name: "ulys-gke",
  location: zone,
  nodeLocations: [zone],
  network: net.vpc.id,
  subnetwork: net.subnet.id,
  masterAuthorizedNetworks: [
    { cidrBlock: config.require("ciRunnerCidr"), displayName: "staging-ci" },
  ],
  nodeMachineType: "e2-standard-2",
  nodeMinCount: 1, nodeMaxCount: 4,
  binAuthzAttestor: ba.attestor.name,
});

const ar = new gcp.artifactregistry.Repository("images", {
  location: region, repositoryId: "ulys", format: "DOCKER",
});

const pg = new Postgres("ulys-pg", {
  name: "ulys-pg", region, vpcId: net.vpc.id,
  tier: "db-custom-1-3840", ha: true, pitr: true,
}, { dependsOn: [net.psaConnection] });

const cache = new Memorystore("ulys-redis", {
  name: "ulys-redis", region, vpcId: net.vpc.id,
  tier: "BASIC", memoryGb: 1, authEnabled: true,
  transitEncryption: "SERVER_AUTHENTICATION",
}, { dependsOn: [net.psaConnection] });

const apiWi = new WorkloadIdentity("api", {
  gsaName: "ulys-api", workloadPool: pulumi.interpolate`${project}.svc.id.goog`,
  ksaNamespace: "ulys", ksaName: "api",
  projectRoles: ["roles/cloudsql.client", "roles/cloudtrace.agent", "roles/logging.logWriter", "roles/monitoring.metricWriter"],
});
const workerWi = new WorkloadIdentity("worker", {
  gsaName: "ulys-worker", workloadPool: pulumi.interpolate`${project}.svc.id.goog`,
  ksaNamespace: "ulys", ksaName: "worker",
  projectRoles: ["roles/cloudtrace.agent", "roles/logging.logWriter", "roles/monitoring.metricWriter"],
});
const esoWi = new WorkloadIdentity("eso", {
  gsaName: "ulys-eso", workloadPool: pulumi.interpolate`${project}.svc.id.goog`,
  ksaNamespace: "external-secrets", ksaName: "external-secrets",
  projectRoles: ["roles/secretmanager.secretAccessor"],
});

new Secret("redis-auth", {
  name: "redis-auth",
  value: cache.instance.authString.apply(s => s ?? ""),
  readers: [apiWi.gsaEmail, esoWi.gsaEmail],
});
new Secret("db-app-password", {
  name: "db-app-password", value: pg.password,
  readers: [apiWi.gsaEmail, esoWi.gsaEmail],
});

export const clusterName     = gke.cluster.name;
export const clusterLocation = gke.cluster.location;
export const artifactRepo    = pulumi.interpolate`${region}-docker.pkg.dev/${project}/${ar.repositoryId}`;
export const dbConnectionName = pg.instance.connectionName;
export const redisHost       = cache.instance.host;
export const redisPort       = cache.instance.port;
export const attestorName    = ba.attestor.name;
export const kubeconfig      = pulumi.secret(gke.kubeconfig());
