import * as path from "node:path";
import { ExtensionContext } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: ExtensionContext): void {
  const serverModule = path.resolve(context.extensionPath, "../../compiler/dist/cli.js");

  const serverOptions: ServerOptions = {
    run: { module: serverModule, args: ["lsp"], transport: TransportKind.stdio },
    debug: { module: serverModule, args: ["lsp"], transport: TransportKind.stdio },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "ring" }],
  };

  client = new LanguageClient("ring-lang", "Ring Language Server", serverOptions, clientOptions);
  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
