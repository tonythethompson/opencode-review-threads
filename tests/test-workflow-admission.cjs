// Execute the admission script from the workflow, rather than copying its matcher.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const workflow = fs.readFileSync('.github/workflows/opencode-bot.yml', 'utf8');
const admission = workflow.split('  admission:\n')[1].split('  opencode-bot:\n')[0];
const script = admission.split('        run: |\n')[1].split('\n').map(line => line.slice(10)).join('\n');
const library = fs.readFileSync('scripts/opencode-action-lib.sh', 'utf8');
const matcher = library.split('opencode_find_mention() {')[1].split('\n\n# Use an explicit prompt')[0];
assert.ok(script.includes('opencode_find_mention() {' + matcher.split('\n').map((line, index) => index === 0 ? line : '  ' + line).join('\n')));
assert.match(workflow, /  opencode-bot:\n[\s\S]*?    needs: admission\n    if: needs\.admission\.outputs\.admitted == 'true'/);
assert.match(admission, /admitted: \$\{\{ steps\.mention\.outputs\.admitted \}\}/);
assert.match(admission, /HAS_MODEL_AND_PROMPT: \$\{\{ inputs\.model != '' && inputs\.prompt != '' \}\}/);
assert.match(admission, /MENTIONS: \$\{\{ inputs\.mentions \|\| '\/opencode,\/oc' \}\}/);
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'admission-'));
try {
  const cases = [];
  for (const mentions of ['/opencode,/oc', '/assistant', ' /assistant , /oc ', '/a.b', '/ASSISTANT', ' /Review Please , /oc ']) {
    for (const body of ['/oc', '/opencode', 'please /OC /review-pr', 'please\n/oc /review-pr', 'please\r\n/opencode /review-pr', 'please\n/opencode /review-pr', 'please\r\n/oc /review-pr', '\t/oc\t/review-pr', 'https://host/oc', 'https://host/opencode', 'x/oc', '/octopus', '/opencode/path', '/oc?x', 'https://host/oc then /oc /review-pr', '/assistant /review-pr', 'please\r\n/assistant /review-pr', '/a.b /review-pr', '/axb /review-pr', '/review please', 'please /REVIEW PLEASE /review-pr']) {
      const expectedMention = mentions.split(',').map(x => x.trim()).filter(Boolean).some(mention => {
        const escaped = mention.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        return new RegExp(`(?:^|\\s)${escaped}(?=\\s|$)`, 'i').test(body);
      });
      cases.push({ mentions, body, expectedMention });
    }
  }
  // Explicit expectations independently cover case folding and literal phrases.
  cases.push(
    { mentions: '/ASSISTANT', body: 'please /assistant /review-pr', expectedMention: true },
    { mentions: '/ASSISTANT', body: '/assistant/path', expectedMention: false },
    { mentions: ' /Review Please ', body: 'please\n/REVIEW PLEASE /review-pr', expectedMention: true },
    { mentions: '/review please', body: '/review', expectedMention: false },
    { mentions: '/review please', body: 'x/review please', expectedMention: false },
    { mentions: '/review please', body: '/review please/path', expectedMention: false },
  );
  for (const event of ['issue_comment', 'pull_request_review_comment']) {
    for (const [model, prompt] of [['', ''], ['provider/model', ''], ['', '/review-pr'], ['provider/model', '/review-pr']]) {
      for (const { mentions, body, expectedMention } of cases) {
        const eventPath = path.join(temp, 'event.json');
        const output = path.join(temp, 'output');
        fs.writeFileSync(eventPath, JSON.stringify({ comment: { body } }));
        fs.writeFileSync(output, '');
        const configured = model !== '' && prompt !== '';
        const result = spawnSync('bash', ['-euo', 'pipefail', '-c', script], { encoding: 'utf8', env: { ...process.env, GITHUB_EVENT_NAME: event, GITHUB_EVENT_PATH: eventPath, GITHUB_OUTPUT: output, MENTIONS: mentions, HAS_MODEL_AND_PROMPT: String(configured) } });
        assert.equal(result.status, 0, result.stderr);
        assert.equal(fs.readFileSync(output, 'utf8'), `admitted=${configured || expectedMention}\n`, JSON.stringify({ event, mentions, body, model, prompt }));
      }
    }
  }
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
console.log('Workflow admission regression matrix passed');
