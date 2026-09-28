# Meio a Meio: finanças da casa

App para organizar as contas da casa, sozinha ou em grupo: despesas divididas, contas recorrentes, parcelas, empréstimos, cartões e acertos. Cada pessoa cria a própria conta (nome, e-mail e senha) dentro do app. Depois cria uma casa ou entra numa casa pelo link de convite.

- `public/index.html`: o app (HTML + JS puro, sem framework)
- `supabase/schema.sql`: tabelas, regras de segurança (RLS), tempo real e bucket de anexos
- `scripts/gen-config.mjs`: gera `public/config.js` com as chaves do Supabase no build da Vercel

## 1. Supabase

1. Crie um projeto em https://supabase.com.
2. Abra **SQL Editor → New query**, cole todo o `supabase/schema.sql` e clique em **Run**.
3. Em **Authentication → Sign In / Providers → Email**:
   - deixe **Email** ativado;
   - para a conta funcionar na hora, sem confirmar e-mail, **desative "Confirm email"**. Se deixar ativado, a pessoa recebe um link de confirmação antes do primeiro acesso.
4. Em **Authentication → URL Configuration**:
   - **Site URL**: o endereço da Vercel (ex.: `https://meio-a-meio.vercel.app`);
   - **Redirect URLs**: adicione `https://meio-a-meio.vercel.app/**`.
5. Em **Project Settings → API**, copie a **Project URL** e a chave **anon / publishable**.

> O envio de e-mails padrão do Supabase tem limite baixo por hora (usado para "esqueci a senha" e para a confirmação). Para muita gente, configure um SMTP próprio em **Authentication → Emails → SMTP Settings**.

## 2. Vercel

1. **Add New → Project** e importe este repositório.
2. Em **Root Directory**, escolha `meio-a-meio`.
3. Em **Environment Variables**, adicione:
   - `SUPABASE_URL`: a Project URL
   - `SUPABASE_ANON_KEY`: a chave anon/publishable

   (Se você conectar o Supabase pela integração da Vercel, as variáveis `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_ANON_KEY` também funcionam.)
4. Clique em **Deploy**. O build/preset já vem do `vercel.json`, então não precisa mudar nada.

## Como as pessoas usam

- Quem acessar o site cria a própria conta e cria uma casa (sozinha ou com outras pessoas).
- Para dividir com alguém: **menu → Pessoas e grupos → Enviar link de convite**. Quem abrir o link cria a conta dela e escolhe o próprio nome na lista.
- Cada casa só é vista por quem entrou nela. Receitas, cartões e contas "só minhas" são vistos apenas pela dona da conta.
- Uma pessoa pode ter várias casas/grupos (viagem, república…).

## Rodar localmente

```bash
cd meio-a-meio
SUPABASE_URL=... SUPABASE_ANON_KEY=... npm run build
npx serve public
```
