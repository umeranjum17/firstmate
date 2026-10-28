#!/usr/bin/env node
import { createRequire } from 'node:module';
import { basename, dirname, join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { readFile, mkdir, rename, writeFile } from 'node:fs/promises';
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import { fileURLToPath } from 'node:url';

const home = process.env.JG_HOME || dirname(dirname(fileURLToPath(import.meta.url)));
const config = process.env.JG_CONFIG_OVERRIDE || join(home, 'config');
const configFile = join(config, 'ai-engine.json');
const member = process.env.BYOKIT_MEMBER || process.env.USER || basename(home);

async function loadApi() {
  if (process.env.JG_BYOKIT_API_MODULE) return import(resolve(process.env.JG_BYOKIT_API_MODULE));
  const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
  const require = createRequire(join(root, 'package.json'));
  const accountsUrl = require.resolve('@byokit/accounts');
  // secrets is a dependency of accounts, so on a clean install it sits inside accounts' own node_modules, not the global root.
  const secretsUrl = createRequire(accountsUrl).resolve('@byokit/secrets');
  return {
    ...(await import(accountsUrl)),
    ...(await import(secretsUrl)),
  };
}

async function accountsApi() {
  const { Accounts, machineStore, osKeyringSeal } = await loadApi();
  if (!Accounts || !machineStore || !osKeyringSeal) throw new Error('the installed BYOKit Accounts API is incomplete');
  const seal = osKeyringSeal({ service: 'byokit' });
  return new Accounts({ store: (id) => machineStore(id, seal), app: 'Juggernaut' });
}

function accountRef(account) {
  return { id: account.id, name: account.name, provider: account.provider };
}

async function setup() {
  const accounts = (await (await accountsApi()).list(member))
    .filter((account) => account.state === 'ready' && account.billing === 'subscription');
  if (!accounts.length) {
    throw new Error('No signed-in BYOKit subscription accounts. Sign in to ChatGPT through a BYOKit Accounts client, then run `bash install.sh` again.');
  }
  accounts.forEach((account, index) => console.log(`${index + 1}. ${account.provider} - ${account.name}${account.email ? ` (${account.email})` : ''}`));
  const rl = createInterface({ input: stdin, output: stdout });
  try {
    const answer = await rl.question('Choose the AI account Juggernaut will use: ');
    if (!/^\d+$/.test(answer) || Number(answer) < 1 || Number(answer) > accounts.length) throw new Error('choose one of the listed account numbers');
    const selected = accountRef(accounts[Number(answer) - 1]);
    await mkdir(config, { recursive: true });
    const temp = `${configFile}.${process.pid}.tmp`;
    await writeFile(temp, `${JSON.stringify({ schema: 1, account: selected }, null, 2)}\n`, { mode: 0o600 });
    await rename(temp, configFile);
    console.log(`Saved ${selected.provider} account ${selected.name} in ${configFile}.`);
  } finally {
    rl.close();
  }
}

async function resolveEngine() {
  const saved = JSON.parse(await readFile(configFile, 'utf8'));
  if (saved.schema !== 1 || !saved.account?.id || !saved.account?.provider) throw new Error(`${configFile} has an invalid account reference`);
  const current = (await (await accountsApi()).list(member)).find((account) =>
    account.id === saved.account.id && account.provider === saved.account.provider && account.state === 'ready' && account.billing === 'subscription');
  if (!current) throw new Error(`Saved BYOKit account ${saved.account.provider}/${saved.account.id} is not signed in. Sign in to ${saved.account.provider} through a BYOKit Accounts client, then run \`bash install.sh\` again.`);
  console.log(JSON.stringify(accountRef(current)));
}

const command = process.argv[2];
try {
  if (command === 'setup') await setup();
  else if (command === 'resolve') await resolveEngine();
  else throw new Error('usage: jg-ai-engine.mjs setup|resolve');
} catch (error) {
  console.error(`AI engine: ${error.message}`);
  process.exitCode = 1;
}
