import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const packageRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export async function metadata(root = packageRoot) {
  const value = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
  if (!/^[a-z0-9-]+$/.test(value.name) || !/^[^/\\]+\.app$/.test(value.nativeApp)) {
    throw new Error('Invalid native application metadata.');
  }
  return value;
}

export function parseArguments(args) {
  if (args.length === 0 || args.includes('--help') || args[0] === 'help') return { command: 'help' };
  if (args.length === 1 && args[0] === '--version') return { command: 'version' };
  const command = args[0];
  if (command !== 'build' && command !== 'install') throw new Error('Use build, install, --help or --version.');
  if (args.length === 1) return { command };
  if (command === 'build' && args.length === 3 && args[1] === '--output' && args[2] && !args[2].startsWith('-')) {
    return { command, output: args[2] };
  }
  throw new Error('Usage: build [--output directory] | install. Existing apps are never overwritten.');
}

export function runProcess(command, args, options) {
  const result = spawnSync(command, args, { ...options, stdio: 'inherit', shell: false });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${path.basename(command)} failed (${result.signal ?? result.status}).`);
}

async function rejectLinks(entry) {
  const stat = await fs.lstat(entry);
  if (stat.isSymbolicLink()) throw new Error('Symbolic links in packaged source are not supported.');
  if (stat.isDirectory()) {
    for (const child of await fs.readdir(entry)) await rejectLinks(path.join(entry, child));
  } else if (!stat.isFile()) throw new Error('Unsupported packaged source entry.');
}

export async function buildApp(options, dependencies = {}) {
  const root = dependencies.root ?? packageRoot;
  const platform = dependencies.platform ?? process.platform;
  const home = dependencies.home ?? os.homedir();
  const cwd = dependencies.cwd ?? process.cwd();
  const run = dependencies.run ?? runProcess;
  if (platform !== 'darwin') throw new Error('This is a native macOS app. Building requires macOS 13+ and Swift 5.9+ (Xcode).');
  if (options.command !== 'build' && options.command !== 'install') throw new Error('An explicit build or install command is required.');
  const info = await metadata(root);
  const output = options.command === 'install' ? path.join(home, 'Applications') : path.resolve(cwd, options.output ?? 'dist');
  const destination = path.join(output, info.nativeApp);
  // Fast refusal before compiling; the final exclusive rename also closes the check/publish race.
  try {
    await fs.lstat(destination);
    throw new Error(`Already exists: ${destination}. Quit the existing app and move it aside before updating.`);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  run('/usr/bin/xcrun', ['--find', 'swift'], { cwd });
  const temporary = await fs.mkdtemp(path.join(dependencies.tmpdir ?? os.tmpdir(), `${info.name}-`));
  let staging;
  try {
    const source = path.join(temporary, 'source');
    await fs.mkdir(source);
    const entries = ['Package.swift', 'Sources', 'Tests', 'Resources', 'build-app.sh'];
    if (info.name === 'claude-limits-macos') entries.push('Login.command');
    for (const entry of entries) {
      const from = path.join(root, entry);
      await rejectLinks(from);
      await fs.cp(from, path.join(source, entry), { recursive: true, errorOnExist: true, force: false });
    }
    run('/bin/bash', [path.join(source, 'build-app.sh')], {
      cwd: source,
      env: { ...process.env,
        CONNECTION_GUARD_BUILD_DIR: path.join(temporary, 'swift-build'),
        CLAUDE_LIMITS_BUILD_DIR: path.join(temporary, 'swift-build'),
        CLANG_MODULE_CACHE_PATH: path.join(temporary, 'clang-cache') }
    });
    const bundle = path.join(source, 'dist', info.nativeApp);
    if (!(await fs.lstat(bundle)).isDirectory()) throw new Error('Build did not produce an application bundle.');
    const publisher = path.join(temporary, 'publish-app');
    run('/usr/bin/xcrun', ['clang', path.join(root, 'lib', 'publish-app.c'), '-o', publisher], { cwd: source });
    await fs.mkdir(output, { recursive: true });
    staging = await fs.mkdtemp(path.join(output, `.${info.name}-`));
    const stagedApp = path.join(staging, info.nativeApp);
    await fs.cp(bundle, stagedApp, { recursive: true, force: false, errorOnExist: true });
    // Publish all bytes at once with RENAME_EXCL. Never clean up or overwrite destination.
    run(publisher, [stagedApp, destination], { cwd: source });
    return destination;
  } finally {
    if (staging) await fs.rm(staging, { recursive: true, force: true });
    await fs.rm(temporary, { recursive: true, force: true });
  }
}

export async function main(args, dependencies = {}) {
  const info = await metadata(dependencies.root ?? packageRoot);
  const options = parseArguments(args);
  const log = dependencies.log ?? console.log;
  if (options.command === 'version') { log(info.version); return; }
  if (options.command === 'help') {
    log(`${info.name} ${info.version}\n${info.description}\n\n` +
      `npx ${info.name} build [--output directory]   Build a .app in ./dist\n` +
      `npx ${info.name} install                      Build and copy to ~/Applications\n\n` +
      'Requires macOS 13+ and Swift 5.9+ (Xcode). No npm install hooks.\n' +
      'Does not launch apps, enable login items, install system extensions or modify the network.\n' +
      'Existing applications are never overwritten. Open the built .app yourself.');
    return;
  }
  const result = await buildApp(options, dependencies);
  log(`Prepared: ${result}\nNot launched. Open this application manually when ready.`);
}
