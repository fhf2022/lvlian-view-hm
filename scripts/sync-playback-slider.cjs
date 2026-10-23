#!/usr/bin/env node
'use strict';

// Standalone check/sync: neither app needs the other checkout to build.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const [mode, peer, ...extra] = process.argv.slice(2);
if (!['--check', '--write'].includes(mode) || !peer || extra.length) {
  console.error('Usage: node scripts/sync-playback-slider.cjs --check|--write <other-repository>');
  process.exit(2);
}
const target = path.resolve(peer);
const normalize = value => value.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
const read = file => normalize(fs.readFileSync(file, 'utf8'));
const files = ['entry/src/main/ets/shared/PlaybackSlider.ets', 'scripts/sync-playback-slider.cjs'];
try {
  if (fs.realpathSync(root) === fs.realpathSync(target)) { throw Error('Choose the other repository.'); }
  if (!fs.existsSync(path.join(target, 'entry/oh-package.json5'))) { throw Error('Target is not an application checkout.'); }
  if (mode === '--write' && !/["']?bundleName["']?\s*:\s*["']com\.harmonycast\.app["']/.test(read(path.join(root, 'AppScope/app.json5')))) {
    throw Error('Run --write from the canonical HarmonyCast checkout; this checkout may use --check.');
  }
  for (const file of files) {
    const source = read(path.join(root, file));
    const destination = path.join(target, file);
    const equal = fs.existsSync(destination) && read(destination) === source;
    if (mode === '--write' && !equal) {
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.writeFileSync(destination, source, 'utf8');
    } else if (mode === '--check' && !equal) {
      console.error('OUT OF SYNC: ' + file);
      process.exitCode = 1;
    }
  }
  if (!process.exitCode) {
    const hash = crypto.createHash('sha256').update(read(path.join(root, files[0]))).digest('hex');
    console.log((mode === '--write' ? 'SYNCED' : 'MATCH') + ' PlaybackSlider ' + hash);
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
