import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";

export interface SecretArgs {
  name: string;
  value: pulumi.Input<string>;
  /**
   * Service accounts that can read this secret. Pass the GSAs that the
   * KSAs (via Workload Identity) impersonate. External Secrets Operator
   * pulls the value into the cluster as a K8s Secret.
   */
  readers: pulumi.Input<string>[];
  /**
   * Optional rotation period. Setting it activates the Secret Manager
   * rotation API; the actual rotation handler lives in a Cloud Function
   * (out of scope for this component — wire it in `infra/stacks/<env>`).
   */
  rotationDays?: number;
}

/**
 * Secret Manager secret with auto-replication, an initial version, and
 * IAM bindings for the GSAs that impersonate the runtime KSAs.
 */
export class Secret extends pulumi.ComponentResource {
  public readonly secret: gcp.secretmanager.Secret;
  public readonly version: gcp.secretmanager.SecretVersion;

  constructor(name: string, args: SecretArgs, opts?: pulumi.ComponentResourceOptions) {
    super("ulys:secrets:Secret", name, {}, opts);

    this.secret = new gcp.secretmanager.Secret(name, {
      secretId: args.name,
      replication: { auto: {} },
      rotation: args.rotationDays ? {
        nextRotationTime: new Date(Date.now() + args.rotationDays * 86400_000).toISOString(),
        rotationPeriod: `${args.rotationDays * 86400}s`,
      } : undefined,
    }, { parent: this });

    this.version = new gcp.secretmanager.SecretVersion(`${name}-v1`, {
      secret: this.secret.id,
      secretData: args.value,
    }, { parent: this });

    for (let i = 0; i < args.readers.length; i++) {
      new gcp.secretmanager.SecretIamMember(`${name}-reader-${i}`, {
        secretId: this.secret.id,
        role: "roles/secretmanager.secretAccessor",
        member: pulumi.interpolate`serviceAccount:${args.readers[i]}`,
      }, { parent: this });
    }

    this.registerOutputs({ secretId: this.secret.secretId });
  }
}
