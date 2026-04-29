import * as gcp from "@pulumi/gcp";
import * as pulumi from "@pulumi/pulumi";

export interface BinAuthzArgs {
  /** "staging" | "prod" — the environment whose images this attestor signs. */
  env: string;
  /** Cosign public key PEM. The matching private key lives only in CI's WIF. */
  cosignPubKeyPem: pulumi.Input<string>;
}

/**
 * Binary Authorization attestor + policy.
 *
 * Image admission flow:
 *   1. CI builds the image, gets the digest.
 *   2. CI runs `cosign sign --key gcpkms://... <digest>`.
 *   3. CI calls Container Analysis to attach the attestation note.
 *   4. The cluster's BinAuthz policy refuses any digest without a valid
 *      attestation from this attestor.
 *
 * Skip on dev: it's friction without protection (developers push images
 * frequently). Apply staging/prod where every digest is reviewed.
 */
export class BinAuthz extends pulumi.ComponentResource {
  public readonly attestor: gcp.binaryauthorization.Attestor;
  public readonly policy: gcp.binaryauthorization.Policy;

  constructor(name: string, args: BinAuthzArgs, opts?: pulumi.ComponentResourceOptions) {
    super("ulys:security:BinAuthz", name, {}, opts);

    const note = new gcp.containeranalysis.Note(`${name}-note`, {
      name: `${name}-note`,
      attestationAuthority: { hint: { humanReadableName: `attestor-${args.env}` } },
    }, { parent: this });

    this.attestor = new gcp.binaryauthorization.Attestor(name, {
      attestationAuthorityNote: {
        noteReference: note.name,
        publicKeys: [{ asciiArmoredPgpPublicKey: args.cosignPubKeyPem }],
      },
    }, { parent: this });

    this.policy = new gcp.binaryauthorization.Policy(`${name}-policy`, {
      defaultAdmissionRule: {
        evaluationMode: "REQUIRE_ATTESTATION",
        enforcementMode: "ENFORCED_BLOCK_AND_AUDIT_LOG",
        requireAttestationsBies: [this.attestor.name],
      },
      admissionWhitelistPatterns: [
        // Allow bootstrap images that ship with GKE Autopilot (kubelet,
        // kube-proxy, calico, gke-gcloud-auth-plugin, etc).
        { namePattern: "gke.gcr.io/*" },
        { namePattern: "k8s.gcr.io/*" },
        { namePattern: "registry.k8s.io/*" },
        { namePattern: "gcr.io/gke-release/*" },
      ],
    }, { parent: this });

    this.registerOutputs({ attestorName: this.attestor.name });
  }
}
