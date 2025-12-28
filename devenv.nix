{ pkgs, ... }:

{
  packages = [
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.curl
    pkgs.git
    pkgs.jq
    pkgs.yq-go
    pkgs.nodejs_20
    pkgs.yarn
    pkgs.skopeo
    pkgs.kubectl
  ];

  scripts = {
    "publish-prod".exec = ''
      ./scripts/publish-prod-nix.sh
    '';

    "publish-prod-nix".exec = ''
      ./scripts/publish-prod-nix.sh
    '';

    "publish-local-dev".exec = ''
      ./scripts/publish-local-dev-nix.sh
    '';

    "publish-local-dev-nix".exec = ''
      ./scripts/publish-local-dev-nix.sh
    '';

    "setup-kargo-backstage".exec = ''
      ./scripts/setup-kargo-backstage-pipeline.sh
    '';

    "publish-ghcr".exec = ''
      ./scripts/publish-ghcr-nix.sh
    '';

    "publish-ghcr-nix".exec = ''
      ./scripts/publish-ghcr-nix.sh
    '';
  };

  enterShell = ''
    echo "devenv ready:"
    echo "  devenv shell publish-local-dev       # Push to Gitea (inner loop)"
    echo "  devenv shell publish-local-dev-nix   # Push to Gitea (inner loop)"
    echo "  devenv shell publish-prod            # Push to Gitea (inner loop)"
    echo "  devenv shell publish-prod-nix        # Push to Gitea (inner loop)"
    echo "  devenv shell publish-ghcr            # Push to GHCR (outer loop) - requires VERSION=x.y.z"
    echo "  devenv shell publish-ghcr-nix        # Push to GHCR (outer loop) - requires VERSION=x.y.z"
    echo "  devenv shell setup-kargo-backstage   # Setup Kargo pipeline"
  '';
}
