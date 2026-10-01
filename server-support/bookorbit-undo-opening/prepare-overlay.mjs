import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [checkout, output] = process.argv.slice(2);
if (!checkout || !output) throw new Error('Usage: node prepare-overlay.mjs BOOKORBIT_CHECKOUT NEW_OUTPUT_DIRECTORY');
const source = resolve(checkout);
const destination = resolve(output);
if (existsSync(destination)) throw new Error('Use a new output directory; do not mix overlay builds');

const modules = [
  'db/schema/index',
  'db/schema/reading-openings',
  'modules/hardcover/hardcover-sync.service',
  'modules/hardcover/hardcover.module',
  'modules/hardcover/hardcover-opening.service',
  'modules/user-book-status/user-book-status.module',
  'modules/user-book-status/reading-opening.repository',
  'modules/user-book-status/reading-opening.service',
  'modules/koreader/koreader.module',
  'modules/koreader/koreader-opening.controller',
  'modules/koreader/koreader-opening.service',
  'modules/koreader/dto/koreader-opening.dto',
];
const files = modules.flatMap((name) => [
  [`server/dist/${name}.js`, `dist/${name}.js`],
  [`server/dist/${name}.js.map`, `dist/${name}.js.map`],
]);
files.push(
  ['server/src/db/migrations/0101_undo_reading_opening.sql', 'migrations/0101_undo_reading_opening.sql'],
  ['server/src/db/migrations/meta/_journal.json', 'migrations/meta/_journal.json'],
  ['server/src/db/migrations/meta/0101_snapshot.json', 'migrations/meta/0101_snapshot.json'],
);
// Read every input before creating output so a missing build fails without a partial context.
const inputs = files.map(([from, to]) => ({ from, to, content: readFileSync(join(source, from)) }));
const manifest = [];
for (const { to, content } of inputs) {
  const target = join(destination, 'overlay', to);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, content);
  manifest.push({ path: `/app/${to}`, sha256: createHash('sha256').update(content).digest('hex') });
}
const here = dirname(fileURLToPath(import.meta.url));
copyFileSync(join(here, 'Dockerfile'), join(destination, 'Dockerfile'));
writeFileSync(join(destination, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Prepared ${manifest.length} overlay files in ${destination}`);
