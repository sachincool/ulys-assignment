/**
 * dev stack — minimum-cost variant of the same architecture.
 *
 * Cluster: Standard GKE, ZONAL (`us-central1-a`), single-zone nodes,
 * 1..3 e2-standard-2 nodes. Free control plane (zonal cluster), spot VMs.
 * Costs: ≈ $20-40/mo for the cluster idle; another ~$15 for Cloud SQL
 * f1-micro and ~$35 for the smallest Memorystore. Total ≈ $70-90/mo.
 *
 * Multi-region upgrade: change `location: zone` to `location: region`
 * (free→ $73/mo for regional control plane), and pass `nodeLocations` to
 * spread workers. This stack is intentionally NOT multi-region.
 */
import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";
import { Network } from "../../components/network";
import { Gke } from "../../components/gke";
import { Postgres } from "../../components/postgres";
import { Memorystore } from "../../components/memorystore";
import { Secret } from "../../components/secrets";
import { WorkloadIdentity } from "../../components/workload-identity";

const region = gcp.config.region ?? "us-central1";
const zone   = `${region}-a`;
const project = gcp.config.project!;

const net = new Network("ulys", { name: "ulys", region });

const gke = new Gke("ulys-gke", {
  name: "ulys-gke",
  location: zone,                            // zonal control plane (free)
  // nodeLocations: omitted — for a zonal cluster, GKE rejects redundant
  // nodeLocations matching the primary zone. Multi-zone HA = pass an
  // array of OTHER zones; multi-region = stamp the stack a second time.
  network: net.vpc.id,
  subnetwork: net.subnet.id,
  masterAuthorizedNetworks: [
    { cidrBlock: "0.0.0.0/0", displayName: "dev-only-do-not-use-in-prod" },
  ],
  nodeMachineType: "e2-standard-2",
  nodeMinCount: 1, nodeMaxCount: 3,
  spot: true,                                // dev-only
});

const ar = new gcp.artifactregistry.Repository("images", {
  location: region, repositoryId: "ulys", format: "DOCKER",
});

const pg = new Postgres("ulys-pg", {
  name: "ulys-pg", region, vpcId: net.vpc.id,
  tier: "db-f1-micro", ha: false, pitr: false,
}, { dependsOn: [net.psaConnection] });

const cache = new Memorystore("ulys-redis", {
  name: "ulys-redis", region, vpcId: net.vpc.id,
  tier: "BASIC", memoryGb: 1,
}, { dependsOn: [net.psaConnection] });

// dependsOn the cluster — workload pool only exists after a GKE cluster
// with WorkloadIdentityConfig has been created in this project.
const apiWi = new WorkloadIdentity("api", {
  gsaName: "ulys-api",
  workloadPool: pulumi.interpolate`${project}.svc.id.goog`,
  ksaNamespace: "ulys", ksaName: "api",
  projectRoles: ["roles/cloudsql.client", "roles/cloudtrace.agent", "roles/logging.logWriter", "roles/monitoring.metricWriter"],
}, { dependsOn: [gke.cluster] });
const workerWi = new WorkloadIdentity("worker", {
  gsaName: "ulys-worker", workloadPool: pulumi.interpolate`${project}.svc.id.goog`,
  ksaNamespace: "ulys", ksaName: "worker",
  projectRoles: ["roles/cloudtrace.agent", "roles/logging.logWriter", "roles/monitoring.metricWriter"],
}, { dependsOn: [gke.cluster] });
const esoWi = new WorkloadIdentity("eso", {
  gsaName: "ulys-eso", workloadPool: pulumi.interpolate`${project}.svc.id.goog`,
  ksaNamespace: "external-secrets", ksaName: "external-secrets",
  projectRoles: ["roles/secretmanager.secretAccessor"],
}, { dependsOn: [gke.cluster] });

// dev's Memorystore is BASIC tier with no AUTH — skip the redis-auth secret
// entirely. The api Deployment references this secret with `optional: true`
// so a missing secret leaves REDIS_PASSWORD unset, which is what we want.
// staging/prod create this secret because they enable AUTH.
new Secret("db-app-password", {
  name: "db-app-password", value: pg.password,
  readers: [apiWi.gsaEmail, esoWi.gsaEmail],
});

export const clusterName     = gke.cluster.name;
export const clusterLocation = gke.cluster.location;
export const artifactRepo    = pulumi.interpolate`${region}-docker.pkg.dev/${project}/${ar.repositoryId}`;
export const dbConnectionName = pg.instance.connectionName;
export const dbPrivateIp     = pg.instance.privateIpAddress;
export const redisHost       = cache.instance.host;
export const redisPort       = cache.instance.port;
export const apiGsaEmail     = apiWi.gsaEmail;
export const workerGsaEmail  = workerWi.gsaEmail;
export const esoGsaEmail     = esoWi.gsaEmail;
export const kubeconfig      = pulumi.secret(gke.kubeconfig());
