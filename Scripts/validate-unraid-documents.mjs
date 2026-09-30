#!/usr/bin/env node
// Validates every Unraid GraphQL document the app sends against a published Unraid API schema.
// usage: node validate-unraid-documents.mjs <schema.graphql> <documents.json> <dir containing node_modules/graphql>
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

const [schemaPath, documentsPath, graphqlDir] = process.argv.slice(2);
if (!schemaPath || !documentsPath || !graphqlDir) {
  console.error('usage: validate-unraid-documents.mjs <schema.graphql> <documents.json> <graphql module dir>');
  process.exit(2);
}
const { buildSchema, parse, validate } = createRequire(join(graphqlDir, 'noop.js'))('graphql');
// The published SDL uses directives the server defines at runtime; declare them so the schema builds.
const sdl = readFileSync(schemaPath, 'utf8');
const preamble = ['usePermissions', 'auth'].filter((name) => sdl.includes(`@${name}`) && !sdl.includes(`directive @${name}`))
  .map((name) => `directive @${name} on FIELD_DEFINITION | OBJECT | MUTATION`).join('\n');
const schema = buildSchema(`${preamble}\n${sdl}`, { assumeValidSDL: true });
const documents = JSON.parse(readFileSync(documentsPath, 'utf8'));

let failures = 0;
for (const [name, text] of Object.entries(documents).sort()) {
  const errors = validate(schema, parse(text));
  if (errors.length) {
    failures += 1;
    console.log(`✘ ${name}\n  ${errors.map((e) => e.message).join('\n  ')}`);
  }
}
console.log(`${Object.keys(documents).length - failures} of ${Object.keys(documents).length} Unraid documents valid against ${schemaPath}`);
process.exit(failures ? 1 : 0);
