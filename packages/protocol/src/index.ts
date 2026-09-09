import { readFileSync } from 'node:fs';
import { Ajv, type ValidateFunction } from 'ajv';
import addFormats from 'ajv-formats';

export * from './contracts.js';

export const schema = JSON.parse(readFileSync(new URL('../schemas/v1.json', import.meta.url), 'utf8'));
export const events: { client: Record<string, string>; server: Record<string, string> } = JSON.parse(
  readFileSync(new URL('../events.json', import.meta.url), 'utf8'),
);
const ajv = new Ajv({ allErrors: false, strict: true, strictRequired: false, validateFormats: true });
// ESM interop for ajv-formats' CommonJS export.
const formats = addFormats as unknown as (instance: Ajv) => void;
formats(ajv);
ajv.addSchema(schema);
const validators = new Map<string, ValidateFunction>();
export function validator(name: string): ValidateFunction {
  if (!Object.hasOwn(schema.definitions, name)) throw new Error('Unknown protocol schema');
  let validate = validators.get(name);
  if (!validate) {
    validate = ajv.compile({ $ref: `${schema.$id}#/definitions/${name}` });
    validators.set(name, validate);
  }
  return validate;
}
export function isValid(name: string, value: unknown): boolean { return Boolean(validator(name)(value)); }
export function isClientPayload(event: string, value: unknown): boolean {
  const name = events.client[event];
  return Boolean(name && isValid(name, value));
}
