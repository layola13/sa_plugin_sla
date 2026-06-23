# SLA Workspace Demo

This demo exercises native `sla` workspace source resolution on top of `sa.mod` workspace manifests.

Build the local CLI once from the plugin root:

```bash
cd /home/vscode/projects/sa_plugins/sa_plugin_sla
zig build
```

Then run from this directory:

```bash
PATH=/home/vscode/projects/sci/zig-out/bin:$PATH /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla check
PATH=/home/vscode/projects/sci/zig-out/bin:$PATH /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla build -p tool
PATH=/home/vscode/projects/sci/zig-out/bin:$PATH /home/vscode/projects/sa_plugins/sa_plugin_sla/zig-out/bin/sla-local-cli sla build-exe -o app_demo
```

The workspace root defaults to the `app` member. `-p tool` selects the `tool` member without passing a source path.
