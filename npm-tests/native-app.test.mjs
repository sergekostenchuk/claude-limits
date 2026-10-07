import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import { mkdirSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { buildApp, main, metadata, parseArguments, packageRoot } from '../lib/native-app.mjs';

async function fixture(t) {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'native-cli-test-'));
  t.after(() => fs.rm(temp, { recursive: true, force: true }));
  const info = await metadata();
  const root = path.join(temp, 'package'); await fs.mkdir(root);
  await fs.writeFile(path.join(root, 'package.json'), JSON.stringify(info));
  for (const name of ['Sources', 'Resources', 'Tests', 'lib']) { await fs.mkdir(path.join(root, name)); }
  for (const name of ['Package.swift', 'build-app.sh', 'Login.command']) await fs.writeFile(path.join(root, name), 'fixture');
  await fs.writeFile(path.join(root, 'lib', 'publish-app.c'), 'fixture');
  const calls = [];
  const dependencies = { root, cwd: temp, home: temp, tmpdir: temp, platform: 'darwin', run: (command, args, options) => {
    calls.push({ command, args });
    if (command === '/bin/bash') {
      // The fake compiler creates only the output bundle; no real build or network call.
      return undefined;
    }
  }};
  return { temp, root, info, calls, dependencies };
}

test('help and version require no build, network, or process execution', async () => {
  const messages = []; const deps = { log: value => messages.push(value), run: () => { throw new Error('unexpected process'); } };
  await main([], deps); await main(['--version'], deps);
  assert.match(messages[0], /No npm install hooks/);
  assert.equal(messages[1], (await metadata()).version);
});
test('argument parser accepts explicit commands and rejects unsupported actions', () => {
  assert.deepEqual(parseArguments(['build', '--output', '/tmp/has space']), { command: 'build', output: '/tmp/has space' });
  for (const args of [['open'], ['install', '--force'], ['build', '--output'], ['install', '--output', '/Applications'], ['build', '--output', '--force']]) {
    assert.throws(() => parseArguments(args));
  }
});
test('non-macOS build is rejected before invoking commands', async () => {
  await assert.rejects(buildApp({ command: 'build' }, { platform: 'linux', run: () => { throw new Error('unexpected'); } }), /macOS/);
});
test('existing app and its data are never overwritten', async t => {
  const f = await fixture(t); const target = path.join(f.temp, 'Applications', f.info.nativeApp);
  await fs.mkdir(target, { recursive: true }); await fs.writeFile(path.join(target, 'keep.txt'), 'existing');
  await assert.rejects(buildApp({ command: 'install' }, f.dependencies), /Already exists/);
  assert.equal(await fs.readFile(path.join(target, 'keep.txt'), 'utf8'), 'existing'); assert.equal(f.calls.length, 0);
});
test('existing symlink destination is never followed', async t => {
  const f = await fixture(t); await fs.mkdir(path.join(f.temp, 'dist'));
  await fs.symlink(path.join(f.temp, 'missing'), path.join(f.temp, 'dist', f.info.nativeApp));
  await assert.rejects(buildApp({ command: 'build' }, f.dependencies), /Already exists/); assert.equal(f.calls.length, 0);
});
test('failed compilation leaves no installed app or temporary source', async t => {
  const f = await fixture(t);
  f.dependencies.run = command => { if (command === '/bin/bash') throw new Error('compiler failed'); };
  await assert.rejects(buildApp({ command: 'install' }, f.dependencies), /compiler failed/);
  assert.deepEqual((await fs.readdir(f.temp)).sort(), ['package']);
});
test('missing build output fails explicitly', async t => {
  const f = await fixture(t); await assert.rejects(buildApp({ command: 'build' }, f.dependencies), /ENOENT/);
  assert.deepEqual((await fs.readdir(f.temp)).sort(), ['package']);
});
test('packaged source symlinks are rejected instead of copying outside files', async t => {
  const f = await fixture(t); await fs.symlink('/etc/hosts', path.join(f.root, 'Sources', 'unexpected'));
  await assert.rejects(buildApp({ command: 'build' }, f.dependencies), /Symbolic links/);
  assert.equal(f.calls.filter(call => call.command === '/bin/bash').length, 0);
});
test('package allowlist excludes local configs and has no install lifecycle scripts', async () => {
  const info = await metadata();
  for (const name of ['preinstall', 'install', 'postinstall', 'prepare', 'prepublish', 'prepublishOnly', 'prepack', 'postpack']) assert.equal(info.scripts?.[name], undefined);
  assert.equal(info.dependencies, undefined); assert.deepEqual(info.os, ['darwin']);
  assert(!info.files.includes('dist')); assert(!info.files.includes('.npmrc')); assert(!info.files.includes('.git'));
  assert.equal((await fs.readFile(path.join(packageRoot, 'bin', 'cli.mjs'), 'utf8')).startsWith('#!/usr/bin/env node'), true);
});

test('successful build copies only the app, without launch or system commands', async t => {
  const f = await fixture(t);
  f.dependencies.run = (command, args, options) => {
    f.calls.push({command, args});
    if (command === '/bin/bash') {
      const contents = path.join(options.cwd, 'dist', f.info.nativeApp, 'Contents');
      mkdirSync(contents, { recursive: true }); writeFileSync(path.join(contents, 'Info.plist'), 'fixture');
    } else if (path.basename(command) === 'publish-app') { renameSync(args[0], args[1]); }
  };
  const result = await buildApp({ command: 'build', output: 'output with spaces' }, f.dependencies);
  assert.equal(result, path.join(f.temp, 'output with spaces', f.info.nativeApp));
  assert.equal(await fs.readFile(path.join(result, 'Contents', 'Info.plist'), 'utf8'), 'fixture');
  assert.deepEqual(f.calls.map(call => path.basename(call.command)), ['xcrun', 'bash', 'xcrun', 'publish-app']);
  assert.deepEqual((await fs.readdir(f.temp)).sort(), ['output with spaces', 'package']);
});
test('competing output created after staging survives publication failure', async t => {
  const f = await fixture(t); const target = path.join(f.temp, 'Applications', f.info.nativeApp);
  f.dependencies.run = (command, args, options) => {
    if (command === '/bin/bash') {
      mkdirSync(path.join(options.cwd, 'dist', f.info.nativeApp), { recursive: true });
    } else if (path.basename(command) === 'publish-app') {
      // Another installer wins after our private copy is complete.
      mkdirSync(target, { recursive: true }); writeFileSync(path.join(target, 'keep'), 'concurrent');
      assert(existsSync(args[0]));
      throw Object.assign(new Error('destination already exists'), {code: 'EEXIST'});
    }
  };
  await assert.rejects(buildApp({ command: 'install' }, f.dependencies), { code: 'EEXIST' });
  assert.equal(await fs.readFile(path.join(target, 'keep'), 'utf8'), 'concurrent');
  assert.deepEqual(await fs.readdir(path.join(f.temp, 'Applications')), [f.info.nativeApp]);
});
test('macOS publisher moves atomically and refuses existing destination', {skip: process.platform !== 'darwin'}, async t => {
  const f = await fixture(t), executable = path.join(f.temp, 'publish-app');
  execFileSync('/usr/bin/xcrun', ['clang', path.join(packageRoot, 'lib/publish-app.c'), '-o', executable]);
  const source = path.join(f.temp, 'source.app'), target = path.join(f.temp, 'target.app');
  await fs.mkdir(source); await fs.writeFile(path.join(source, 'ours'), 'ours');
  await fs.mkdir(target); await fs.writeFile(path.join(target, 'theirs'), 'theirs');
  assert.throws(() => execFileSync(executable, [source, target], {stdio: 'pipe'}));
  assert.equal(await fs.readFile(path.join(target, 'theirs'), 'utf8'), 'theirs');
  assert.equal(await fs.readFile(path.join(source, 'ours'), 'utf8'), 'ours');
  const fresh = path.join(f.temp, 'fresh.app');
  execFileSync(executable, [source, fresh]);
  assert.equal(await fs.readFile(path.join(fresh, 'ours'), 'utf8'), 'ours');
  assert.equal(existsSync(source), false);
});
