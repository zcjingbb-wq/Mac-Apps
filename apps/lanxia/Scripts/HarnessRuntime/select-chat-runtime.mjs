import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

const install = resolve(process.argv[2]);
const lock = JSON.parse(readFileSync(join(install, "package-lock.json"), "utf8"));
const available = new Set(Object.keys(lock.packages).filter(path =>
    path.startsWith("node_modules/") && existsSync(join(install, path, "package.json"))
));

// The CLI entry and SDK stdio startup export also advertise dependencies for
// other profiles. Keep the imports of these two entry points and the isolated
// SDK bundle. Ordinary packages keep their complete npm dependency closure.
const selectedImports = new Map([
    ["node_modules/@deepseek-ai/dsh", [
        "@deepseek-ai/dsh-app-boot",
        "@deepseek-ai/dsh-cmdline",
        "@deepseek-ai/dsh-home-paths",
        "@deepseek-ai/dsh-http-proxy",
        "@deepseek-ai/dsh-launch-environment",
        "@deepseek-ai/dsh-official-bundles",
        "@deepseek-ai/dsh-sdk-minimal",
        "commander",
    ]],
    ["node_modules/@deepseek-ai/dsh-sdk-app", [
        "@deepseek-ai/dsh-cmdline",
        "@deepseek-ai/schemastery",
        "commander",
    ]],
]);

function locateDependency(owner, name) {
    for (let directory = owner; ; directory = dirname(directory)) {
        if (basename(directory) !== "node_modules") {
            const candidate = join(directory, "node_modules", name);
            if (available.has(candidate)) return candidate;
        }
        if (directory === ".") return undefined;
    }
}

const retained = new Set();
const queue = ["node_modules/@deepseek-ai/dsh"];
for (const path of queue) {
    if (retained.has(path)) continue;
    retained.add(path);
    const metadata = lock.packages[path];
    const dependencies = selectedImports.get(path) ?? Object.keys({
        ...metadata.dependencies,
        ...metadata.optionalDependencies,
        ...metadata.peerDependencies,
    });
    for (const name of dependencies) {
        const dependency = locateDependency(path, name);
        if (dependency) queue.push(dependency);
        else if (selectedImports.has(path)) throw new Error(`Missing required SDK package ${name}`);
    }
}

for (const path of available) {
    if (!retained.has(path)) rmSync(join(install, path), { recursive: true, force: true });
}

// The pinned adapter defaults to uploading image attachments to the Files API.
// Send confirmed images inline in the model request without creating a remote file.
const adapterPath = "node_modules/@deepseek-ai/dsh-llm-deepseek";
const adapter = join(install, adapterPath, "lib/index.js");
const original = readFileSync(adapter, "utf8");
const uploadFirst = "let inline = false;";
if (lock.packages[adapterPath]?.version !== "0.2.2-rc.5" || original.split(uploadFirst).length !== 2) {
    throw new Error("Review inline image handling for this DeepSeek adapter version");
}
writeFileSync(adapter, original.replace(uploadFirst, "let inline = versions.size > 0;"));
