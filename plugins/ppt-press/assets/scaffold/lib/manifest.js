#!/usr/bin/env node
'use strict';

const fs   = require('fs');
const path = require('path');

const BASE_URL = process.env.PPT_SITE_URL || 'http://localhost:4321';

/**
 * 读取构建产物 dist/manifest.json（由 src/integrations/manifest-gen.ts 生成）。
 * 若未构建，fallback 扫描 src/pages/decks/ 目录名列表（开发时使用）。
 */
function buildManifest(repoRoot) {
  const distManifest = path.join(repoRoot, 'dist', 'manifest.json');
  if (fs.existsSync(distManifest)) {
    return JSON.parse(fs.readFileSync(distManifest, 'utf8'));
  }

  const pagesDecks = path.join(repoRoot, 'src', 'pages', 'decks');
  const decks = [];
  if (fs.existsSync(pagesDecks)) {
    for (const entry of fs.readdirSync(pagesDecks, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      decks.push({
        name:  entry.name,
        title: entry.name,
        type:  'public',
        path:  `decks/${entry.name}/`,
        url:   `${BASE_URL}/decks/${entry.name}/`,
      });
    }
    decks.sort((a, b) => a.name.localeCompare(b.name));
  }

  return { base_url: BASE_URL, generated_at: new Date().toISOString(), decks };
}

module.exports = { buildManifest, BASE_URL };
