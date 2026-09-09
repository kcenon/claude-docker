const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { digest } = require('issue335-digest');
const output = process.env.ISSUE335_OUTPUT_ROOT;
const manifest = JSON.parse(fs.readFileSync(path.join(output, 'manifest.json')));
assert.equal(manifest.files, 1000);
assert.equal(manifest.bytes, 32768);
assert.equal(digest(Buffer.from('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
let reads = 0;
for (let pass = 0; pass < 5; pass++) {
  for (let index = 0; index < manifest.files; index++) {
    const data = fs.readFileSync(path.join(output, String(index)));
    assert.equal(data.length, manifest.bytes);
    assert.equal(digest(data), manifest.digest);
    reads++;
  }
}
assert.equal(reads, 5000);
process.stdout.write('ISSUE335_WORKLOAD_OK\n');
