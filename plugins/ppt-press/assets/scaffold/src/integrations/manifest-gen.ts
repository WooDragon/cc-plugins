import fs   from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { AstroIntegration } from 'astro';

export default function manifestGen(): AstroIntegration {
  return {
    name: 'manifest-gen',
    hooks: {
      'astro:build:done': ({ dir }) => {
        const distPath  = fileURLToPath(dir);
        const decksPath = path.join(distPath, 'decks');
        const baseUrl   = process.env.PPT_SITE_URL || 'http://localhost:4321';

        if (!fs.existsSync(decksPath)) {
          fs.writeFileSync(
            path.join(distPath, 'manifest.json'),
            JSON.stringify({ base_url: baseUrl, generated_at: new Date().toISOString(), decks: [] }, null, 2),
          );
          return;
        }

        const entries = fs.readdirSync(decksPath, { withFileTypes: true });
        const decks: Array<Record<string, string>> = [];

        for (const entry of entries) {
          if (!entry.isDirectory()) continue;
          const indexPath = path.join(decksPath, entry.name, 'index.html');
          if (!fs.existsSync(indexPath)) continue;

          const html       = fs.readFileSync(indexPath, 'utf8');
          const titleMatch = html.match(/<title>(.*?)<\/title>/i);
          const title      = titleMatch ? titleMatch[1] : entry.name;

          decks.push({
            name:  entry.name,
            title,
            type:  'public',
            path:  `decks/${entry.name}/`,
            url:   `${baseUrl}/decks/${entry.name}/`,
          });
        }

        decks.sort((a, b) => a.name.localeCompare(b.name));

        fs.writeFileSync(
          path.join(distPath, 'manifest.json'),
          JSON.stringify({ base_url: baseUrl, generated_at: new Date().toISOString(), decks }, null, 2),
        );

        console.log(`[manifest-gen] wrote manifest.json (${decks.length} decks)`);
      },
    },
  };
}
