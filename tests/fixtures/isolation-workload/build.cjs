const fs = require('node:fs');
const path = require('node:path');
const { digest } = require('issue335-digest');
const output = process.env.ISSUE335_OUTPUT_ROOT;
if (!output) throw Error('Missing fixture output directory');
fs.mkdirSync(output, { recursive: true });
const block = Buffer.alloc(32768, 42);
for (let index = 0; index < 1000; index++) {
  fs.writeFileSync(path.join(output, String(index)), block);
}
fs.writeFileSync(path.join(output, 'manifest.json'), JSON.stringify({
  files: 1000, bytes: block.length, digest: digest(block)
}));
