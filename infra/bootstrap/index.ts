/**
 * Bootstrap stack — run ONCE per env, from a laptop, against the env's GCP
 * project. Creates:
 *   - the Pulumi state bucket (KMS-encrypted, versioned)
 *   - the Workload Identity Pool + Provider that GitHub Actions assumes
 *   - the deployer GSA + a CURATED role set (no Owner)
 *
 * Backend: local file (./pulumi-state). After this runs, copy the state
 * bucket name into the env stack's Pulumi.<env>.yaml backend config and
 * never touch this stack again.
 *
 * Why local backend: the bucket this stack creates IS the backend for
 * everything else. Bottom-turtle bootstrap.
 */
import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";

const config = new pulumi.Config();
const env = pulumi.getStack();              // "dev-bootstrap" | "staging-bootstrap" | "prod-bootstrap"
const githubRepo = config.require("githubRepo"); // "owner/repo"
const project = gcp.config.project!;
const region = config.get("region") ?? "us-central1";

// State bucket — uniform IAM, versioned, lifecycle-pruned.
//
// CMEK-on-state was the original design but provisioning the GCS
// service identity right after the project is created is racy. Uniform
// IAM is the real protection; CMEK is defense-in-depth that's worth
// adding LATER once the GCS service identity has settled. For prod, we
// keep the data-layer KMS keys (in the env stack) — that's where the
// privacy concern actually sits.
const stateBucket = new gcp.storage.Bucket("pulumi-state", {
  name: `${project}-pulumi-state`,
  location: region,
  uniformBucketLevelAccess: true,
  versioning: { enabled: true },
  lifecycleRules: [{
    condition: { numNewerVersions: 10 },
    action:    { type: "Delete" },
  }],
});

// Workload Identity Federation — GitHub Actions OIDC → GSA.
const wifPool = new gcp.iam.WorkloadIdentityPool("github", {
  workloadIdentityPoolId: `github-${env}`,
});

const wifProvider = new gcp.iam.WorkloadIdentityPoolProvider("github", {
  workloadIdentityPoolId: wifPool.workloadIdentityPoolId,
  workloadIdentityPoolProviderId: "github-provider",
  attributeMapping: {
    "google.subject":         "assertion.sub",
    "attribute.repository":   "assertion.repository",
    "attribute.ref":          "assertion.ref",
    "attribute.environment":  "assertion.environment", // bind to GH Environment
  },
  // Pin trust to one repo AND require a GH Environment matching this
  // bootstrap's env (e.g. attribute.environment == "prod").
  attributeCondition: pulumi.interpolate`assertion.repository == "${githubRepo}" && assertion.environment == "${env.replace(/-bootstrap$/, "")}"`,
  oidc: {
    issuerUri: "https://token.actions.githubusercontent.com",
  },
});

// Curated role set per env — no Owner. Adjust as new resources land.
const baseRoles = [
  "roles/artifactregistry.writer",
  "roles/cloudkms.cryptoKeyEncrypterDecrypter",
  "roles/cloudsql.admin",
  "roles/compute.networkAdmin",
  "roles/compute.securityAdmin",
  "roles/container.admin",
  "roles/container.clusterAdmin",
  "roles/iam.serviceAccountAdmin",
  "roles/iam.serviceAccountUser",
  "roles/redis.admin",
  "roles/secretmanager.admin",
  "roles/servicenetworking.networksAdmin",
  "roles/serviceusage.serviceUsageAdmin",
  "roles/storage.admin",
];
// prod adds budgets + binauthz; dev/staging skip.
const prodOnly = ["roles/billing.user", "roles/binaryauthorization.policyEditor"];
const roles = env.startsWith("prod") ? [...baseRoles, ...prodOnly] : baseRoles;

const deployer = new gcp.serviceaccount.Account("gh-deployer", {
  accountId: `gh-deployer-${env}`,
  displayName: `GitHub Actions deployer (${env})`,
});

new gcp.serviceaccount.IAMMember("deployer-wif", {
  serviceAccountId: deployer.name,
  role: "roles/iam.workloadIdentityUser",
  member: pulumi.interpolate`principalSet://iam.googleapis.com/${wifPool.name}/attribute.repository/${githubRepo}`,
});

for (const role of roles) {
  new gcp.projects.IAMMember(`deployer-${role.split("/").pop()}`, {
    project,
    role,
    member: pulumi.interpolate`serviceAccount:${deployer.email}`,
  });
}

export const stateBucketName = stateBucket.name;
export const wifProviderResource = wifProvider.name;
export const deployerSaEmail = deployer.email;
