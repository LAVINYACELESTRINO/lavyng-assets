// Gera public/config.js a partir das variáveis de ambiente (roda no build da Vercel).
// Aceita os nomes criados pela integração Supabase da Vercel.
import { writeFileSync } from 'node:fs';

const env = process.env;
const url = env.SUPABASE_URL || env.NEXT_PUBLIC_SUPABASE_URL;
const key = env.SUPABASE_ANON_KEY || env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  || env.SUPABASE_PUBLISHABLE_KEY || env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!url || !key) {
  console.error('Faltam SUPABASE_URL e SUPABASE_ANON_KEY nas variáveis de ambiente.');
  process.exit(1);
}

writeFileSync(
  new URL('../public/config.js', import.meta.url),
  `window.MAM_CONFIG=${JSON.stringify({ url, key })};\n`,
);
console.log('public/config.js gerado para', url);
