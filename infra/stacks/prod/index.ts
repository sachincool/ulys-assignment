/**
 * prod stack — Standard GKE, REGIONAL control plane (HA across the
 * region's zones), nodes pinned to one zone for cost. Cloud SQL HA + PITR,
 * Memorystore STANDARD_HA with AUTH + TLS, BinAuthz on.
 *
 * Multi-region note: keep this stack ZONAL nodes for now. The
 * multi-region upgrade path is to copy this stack to `prod-eu` (or
 * wherever) and use Cloud Load Balancer with multi-region NEGs to
 * distribute. We do not span one cluster across regions — that's
 * operationally painful for marginal benefit.
 *
 * Costs ≈ $250/mo idle:
 *   GKE regional control plane $73 + 1× e2-standard-2 node $50
 *   Cloud SQL HA db-custom-2-7680 $90
 *   Memorystore STANDARD_HA 5GB ~$70
 *   LB + Cloud Logging + Trace + a few extras ~$30
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
const project = gcp.config.project!;

const net = new Network("ulys", { name: "ulys", region });

const ba = new BinAuthz("attestor-prod", {
  env: "prod",
  cosignPubKeyPem: config.requireSecret("cosignPubKeyPem"),
});

const gke = new Gke("ulys-gke", {
  name: "ulys-gke",
  location: region,                      // REGIONAL control plane
  nodeLocations: [`${region}-a`],        // single zone for cost; flip
                                         // to all 3 zones for zonal HA.
  network: net.vpc.id,
  subnetwork: net.subnet.id,
  masterAuthorizedNetworks: [
    { cidrBlock: config.require("ciRunnerCidr"), displayName: "prod-ci" },
  ],
  nodeMachineType: "e2-standard-2",
  nodeMinCount: 1, nodeMaxCount: 5,
  binAuthzAttestor: ba.attestor.name,
});

const ar = new gcp.artifactregistry.Repository("images", {
  location: region, repositoryId: "ulys", format: "DOCKER",
});

// CMEK for the data layer.
const kmsRing = new gcp.kms.KeyRing("data", { location: region, name: "data" });
const sqlKey  = new gcp.kms.CryptoKey("sql", {
  keyRing: kmsRing.id, name: "sql", purpose: "ENCRYPT_DECRYPT",
  rotationPeriod: "7776000s",
});
const cloudSqlAgent = pulumi.interpolate`service-${gcp.organizations.getProject({}).then(p => p.number)}@gcp-sa-cloud-sql.iam.gserviceaccount.com`;
new gcp.kms.CryptoKeyIAMMember("sql-key-grant", {
  cryptoKeyId: sqlKey.id,
  role: "roles/cloudkms.cryptoKeyEncrypterDecrypter",
  member: pulumi.interpolate`serviceAccount:${cloudSqlAgent}`,
});

const pg = new Postgres("ulys-pg", {
  name: "ulys-pg", region, vpcId: net.vpc.id,
  tier: "db-custom-2-7680", ha: true, pitr: true, diskSizeGb: 50,
  kmsKey: sqlKey.id,
}, { dependsOn: [net.psaConnection] });

const cache = new Memorystore("ulys-redis", {
  name: "ulys-redis", region, vpcId: net.vpc.id,
  tier: "STANDARD_HA", memoryGb: 5,
  authEnabled: true, transitEncryption: "SERVER_AUTHENTICATION",
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
  rotationDays: 7,
});

new gcp.billing.Budget("prod-budget", {
  billingAccount: config.require("billingAccount"),
  displayName: "ulys-prod budget",
  budgetFilter: { projects: [`projects/${project}`] },
  amount: { specifiedAmount: { currencyCode: "USD", units: "300" } },
  thresholdRules: [
    { thresholdPercent: 0.5 },
    { thresholdPercent: 0.9 },
    { thresholdPercent: 1.0 },
  ],
});

export const clusterName     = gke.cluster.name;
export const clusterLocation = gke.cluster.location;
export const artifactRepo    = pulumi.interpolate`${region}-docker.pkg.dev/${project}/${ar.repositoryId}`;
export const dbConnectionName = pg.instance.connectionName;
export const redisHost       = cache.instance.host;
export const redisPort       = cache.instance.port;
export const attestorName    = ba.attestor.name;
export const kubeconfig      = pulumi.secret(gke.kubeconfig());
