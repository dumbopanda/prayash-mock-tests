import { createClient } from './supabase.js'; // supabase-js 2.45.4, bundled so the app starts offline

// Publishable key: safe in the browser, access is enforced by row-level security.
export const sb = createClient(
  'https://rfenuwnboyktdprlmgct.supabase.co',
  'sb_publishable_XWZt491GsJ8Ze1NTLgmXqA__Xw4H5jW'
);

export async function currentUser() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return null;
  const { data: p } = await sb.from('profiles').select('role,name').eq('id', session.user.id).single();
  return { id: session.user.id, email: session.user.email, ...p };
}

// ponytail: falls back to the old signatures (no p_id / p_attempt) until db/2026-10-22_attempts_history.sql
// is applied in Supabase; remove the fallback after that.
export async function rpc(name, args = {}) {
  const r = await sb.rpc(name, args);
  if (r.error?.code !== 'PGRST202' || !('p_id' in args || 'p_attempt' in args)) return r;
  const { p_id, p_attempt, ...rest } = args;
  return sb.rpc(name, rest);
}

export async function logout() {
  await sb.auth.signOut();
  location.href = 'index.html';
}

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
