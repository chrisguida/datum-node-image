{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "node-wizard";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      ./main.go
      ./auth.go
      ./address.go
      ./i18n.go
      ./node.go
      ./poolstats.go
      ./hashrate.go
      ./dashboard.go
      ./locales
      ./templates
    ];
  };

  vendorHash = "sha256-xGPzODAJOls8RyyYdoEbPqz63i4oex41QsF1HNpmWAc=";

  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "First-boot setup page and status dashboard for the datum-node-image";
    license = lib.licenses.mit;
    mainProgram = "node-wizard";
  };
}
