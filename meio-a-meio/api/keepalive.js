// Chamado 1x por dia pelo cron da Vercel (vercel.json) para o Supabase do plano gratuito
// não pausar o projeto por falta de uso.
export default async function handler(req, res) {
  const url = process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_ANON_KEY || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
    || process.env.SUPABASE_PUBLISHABLE_KEY || process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  const r = await fetch(`${url}/rest/v1/rpc/ping`, {
    method: 'POST',
    headers: { apikey: key, 'Content-Type': 'application/json' },
    body: '{}',
  });
  res.status(r.ok ? 200 : 502).json({ ok: r.ok });
}
