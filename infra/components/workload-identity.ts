import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";

export interface WorkloadIdentityArgs {
  /** GSA account_id, e.g. "api". */
  gsaName: string;
  /** Roles to grant the GSA at the project level. Keep this tight. */
  projectRoles?: pulumi.Input<string>[];
  /**
   * Cluster's workload identity pool, e.g. `<project>.svc.id.goog`.
   * Get this from `GkeAutopilot.cluster.workloadIdentityConfig.workloadPool`.
   */
  workloadPool: pulumi.Input<string>;
  /** K8s namespace + ServiceAccount name allowed to impersonate this GSA. */
  ksaNamespace: string;
  ksaName: string;
}

/**
 * Workload Identity binding: a GCP service account that a Kubernetes
 * ServiceAccount in the cluster can impersonate, plus an annotation hint
 * the manifest in the GitOps repo will use:
 *
 *   metadata:
 *     annotations:
 *       iam.gke.io/gcp-service-account: <emit `output.gsaEmail` here>
 *
 * The pod runs as the KSA → impersonates the GSA → makes Google API calls
 * with the GSA's IAM. No JSON keys, no DB password on the network.
 */
export class WorkloadIdentity extends pulumi.ComponentResource {
  public readonly gsa: gcp.serviceaccount.Account;
  public readonly gsaEmail: pulumi.Output<string>;

  constructor(name: string, args: WorkloadIdentityArgs, opts?: pulumi.ComponentResourceOptions) {
    super("ulys:iam:WorkloadIdentity", name, {}, opts);

    this.gsa = new gcp.serviceaccount.Account(name, {
      accountId: args.gsaName,
      displayName: `WI: ${args.ksaNamespace}/${args.ksaName}`,
    }, { parent: this });
    this.gsaEmail = this.gsa.email;

    new gcp.serviceaccount.IAMMember(`${name}-wi`, {
      serviceAccountId: this.gsa.name,
      role: "roles/iam.workloadIdentityUser",
      member: pulumi.interpolate`serviceAccount:${args.workloadPool}[${args.ksaNamespace}/${args.ksaName}]`,
    }, { parent: this });

    for (let i = 0; i < (args.projectRoles ?? []).length; i++) {
      new gcp.projects.IAMMember(`${name}-role-${i}`, {
        project: gcp.config.project!,
        role: args.projectRoles![i],
        member: pulumi.interpolate`serviceAccount:${this.gsaEmail}`,
      }, { parent: this });
    }

    this.registerOutputs({ gsaEmail: this.gsaEmail });
  }
}
