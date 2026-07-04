#!/usr/bin/env node
/**
 * list-decks.js — 本地 deck 检索工具
 *
 * 用法：
 *   node scripts/list-decks.js                  # 列出所有 deck
 *   node scripts/list-decks.js --search <kw>     # 按 name/title 模糊搜索
 *   node scripts/list-decks.js --copy <name>     # 复制 URL 到剪贴板（精确匹配）
 *   node scripts/list-decks.js --json            # 原始 JSON 输出（bot/管道用）
 */

'use strict';

const path              = require('path');
const { execFileSync }  = require('child_process');
const { buildManifest } = require('../lib/manifest');

const REPO_ROOT = path.resolve(__dirname, '..');

function main() {
  const args     = process.argv.slice(2);
  const manifest = buildManifest(REPO_ROOT);
  const { decks } = manifest;

  // --json: 原始 JSON，供 bot / 管道消费
  if (args.includes('--json')) {
    process.stdout.write(JSON.stringify(manifest, null, 2) + '\n');
    return;
  }

  // --copy <name>: 精确匹配，复制 URL 到剪贴板
  const copyIdx = args.indexOf('--copy');
  if (copyIdx !== -1) {
    const name = args[copyIdx + 1];
    if (!name) {
      process.stderr.write('用法: --copy <deck-name>\n');
      process.exit(1);
    }
    const deck = decks.find(d => d.name === name);
    if (!deck) {
      process.stderr.write(`未找到 deck: "${name}"\n`);
      process.stderr.write(`可用: ${decks.map(d => d.name).join(', ') || '（无）'}\n`);
      process.exit(1);
    }
    if (process.platform === 'darwin') {
      execFileSync('pbcopy', { input: deck.url });
      process.stdout.write(`已复制到剪贴板: ${deck.url}\n`);
    } else {
      process.stdout.write(`${deck.url}\n`);
    }
    return;
  }

  // --search <keyword>: name/title 大小写不敏感模糊匹配
  let filtered = decks;
  const searchIdx = args.indexOf('--search');
  if (searchIdx !== -1) {
    const kw = (args[searchIdx + 1] || '').toLowerCase();
    if (!kw) {
      process.stderr.write('用法: --search <keyword>\n');
      process.exit(1);
    }
    filtered = decks.filter(d =>
      d.name.toLowerCase().includes(kw) ||
      d.title.toLowerCase().includes(kw)
    );
  }

  // 列表输出
  if (filtered.length === 0) {
    process.stdout.write('没有找到匹配的 deck\n');
    return;
  }

  const nameW = Math.max(4, ...filtered.map(d => d.name.length));
  const typeW = Math.max(4, ...filtered.map(d => d.type.length));

  process.stdout.write(
    ` ${'#'.padStart(2)}  ${'Name'.padEnd(nameW)}  ${'Type'.padEnd(typeW)}  Title\n`
  );
  process.stdout.write(
    ` ${'─'.repeat(2)}  ${'─'.repeat(nameW)}  ${'─'.repeat(typeW)}  ${'─'.repeat(30)}\n`
  );

  filtered.forEach((d, i) => {
    process.stdout.write(
      ` ${String(i + 1).padStart(2)}  ${d.name.padEnd(nameW)}  ${d.type.padEnd(typeW)}  ${d.title}\n`
    );
    process.stdout.write(`      ${d.url}\n`);
  });

  process.stdout.write(`\n共 ${filtered.length} 个 deck`);
  if (filtered.length < decks.length) {
    process.stdout.write(` (过滤自 ${decks.length} 个)`);
  }
  process.stdout.write('\n提示: --copy <name> 复制 URL | --search <kw> 搜索 | --json JSON 输出\n');
}

main();
