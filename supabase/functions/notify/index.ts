// =====================================================================
// Les Camélias : envoi des notifications sur téléphone (Web Push).
// Fonction Supabase « notify ». À coller dans Supabase > Edge Functions >
// Deploy a new function > Via Editor, sous le nom « notify », puis Deploy.
//
// Aucun réglage ni secret à saisir : la fonction lit elle-même ses clés
// dans la base (table push_config, inaccessible depuis le navigateur).
// Le contenu des notifications est chiffré de bout en bout jusqu'au téléphone
// (RFC 8291) : le service de notification du fabricant ne peut pas le lire.
// =====================================================================

const SB_URL = Deno.env.get("SUPABASE_URL");
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const ANON = Deno.env.get("SUPABASE_ANON_KEY");
const SITE = "https://lescameliats.fr/";
const CONTACT = "mailto:contact@lescameliats.fr";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// ---------- Outils ----------
const enc = new TextEncoder();
const b64u = (buf) => {
  const b = new Uint8Array(buf); let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const unb64u = (str) => {
  const s = atob(str.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((str.length + 3) % 4));
  const b = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i);
  return b;
};
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
const subtle = crypto.subtle;

async function rpc(fn, args, token) {
  const key = token ? ANON : SERVICE;
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${token || SERVICE}`, "Content-Type": "application/json" },
    body: JSON.stringify(args || {}),
  });
  if (!r.ok) throw new Error(`${fn} : ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}

// ---------- Clés VAPID (identité du serveur auprès des services de notification) ----------
async function vapidKeys() {
  const rows = await rpc("push_vapid");
  const row = Array.isArray(rows) ? rows[0] : rows;
  if (row && row.vapid_public && row.vapid_private) return row;
  const kp = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pub = b64u(await subtle.exportKey("raw", kp.publicKey));
  const priv = JSON.stringify(await subtle.exportKey("jwk", kp.privateKey));
  await rpc("push_set_vapid", { p_public: pub, p_private: priv });
  const again = await rpc("push_vapid");             // une autre requête a pu les créer en même temps
  return Array.isArray(again) ? again[0] : again;
}

async function vapidHeader(endpoint, keys) {
  const aud = new URL(endpoint).origin;
  const head = b64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = b64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: CONTACT })));
  const key = await subtle.importKey("jwk", JSON.parse(keys.vapid_private), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${head}.${body}`));
  return `vapid t=${head}.${body}.${b64u(sig)}, k=${keys.vapid_public}`;
}

// ---------- Chiffrement du message (RFC 8291, aes128gcm) ----------
async function hkdf(salt, ikm, info, bytes) {
  const k = await subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, k, bytes * 8));
}
export async function encryptPayload(text, p256dh, authSecret, fixed) {
  const uaPublic = unb64u(p256dh), auth = unb64u(authSecret);
  let asPrivate, asPublic;
  if (fixed) {                                            // clés imposées : uniquement pour les tests
    asPublic = unb64u(fixed.asPublic);
    asPrivate = await subtle.importKey("jwk", { kty: "EC", crv: "P-256", d: fixed.asPrivate,
      x: b64u(asPublic.slice(1, 33)), y: b64u(asPublic.slice(33, 65)), ext: true }, { name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  } else {
    const kp = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
    asPrivate = kp.privateKey; asPublic = new Uint8Array(await subtle.exportKey("raw", kp.publicKey));
  }
  const uaKey = await subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const shared = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: uaKey }, asPrivate, 256));
  const ikm = await hkdf(auth, shared, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const salt = fixed ? unb64u(fixed.salt) : crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);
  const key = await subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const cipher = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, concat(enc.encode(text), new Uint8Array([2]))));
  const header = new Uint8Array(21); header.set(salt, 0); new DataView(header.buffer).setUint32(16, 4096); header[20] = 65;
  return concat(header, asPublic, cipher);
}

async function sendOne(sub, message, keys, urgent) {
  const body = await encryptPayload(JSON.stringify(message), sub.p256dh, sub.auth);
  const r = await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      Authorization: await vapidHeader(sub.endpoint, keys),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: "86400",
      Urgency: urgent ? "high" : "normal",
    },
    body,
  });
  if (r.status === 404 || r.status === 410) { await rpc("push_forget", { p_endpoint: sub.endpoint }); return "gone"; }
  return r.ok ? "ok" : `erreur ${r.status}`;
}

// ---------- Textes des notifications ----------
const STATUS = { reported: "Signalé", in_progress: "En cours", resolved: "Résolu" };
function messageFor(event, d) {
  const n = d.num ? `#${d.num}` : "";
  if (event === "urgent") return { title: `URGENT · signalement ${n}`, body: `${d.title} · ${d.location}`, url: `${SITE}#t${d.num}`, tag: `t${d.num}` };
  if (event === "new") return { title: `Nouveau signalement ${n}`, body: `${d.title} · ${d.location}`, url: `${SITE}#t${d.num}`, tag: `t${d.num}` };
  if (event === "status") return { title: `${n} : ${STATUS[d.status] || d.status}`, body: d.title, url: `${SITE}#t${d.num}`, tag: `t${d.num}` };
  if (event === "access") return { title: "Nouvelle demande d'accès", body: `${d.name} attend votre validation.`, url: `${SITE}#admin`, tag: "access" };
  return { title: "Les Camélias", body: "Les notifications fonctionnent sur cet appareil.", url: SITE, tag: "test" };
}

async function sendAll(targets, message, urgent) {
  const keys = await vapidKeys();
  const res = await Promise.allSettled((targets || []).map((t) => sendOne(t, message, keys, urgent)));
  return res.map((r) => (r.status === "fulfilled" ? r.value : String(r.reason)));
}

// ---------- Point d'entrée ----------
export async function handle(req) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST attendu" }, 405);
  let p; try { p = await req.json(); } catch { return json({ error: "JSON attendu" }, 400); }
  try {
    if (p.action === "init") {                      // le navigateur demande la clé publique
      const keys = await vapidKeys();
      return json({ publicKey: keys.vapid_public });
    }
    if (p.action === "test") {                      // essai : seulement les appareils de la personne connectée
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const mine = await rpc("push_my_targets", {}, token);
      return json({ sent: await sendAll(mine, messageFor("test", {}), false) });
    }
    if (p.action === "event") {                     // appelé par la base, avec le secret partagé
      const targets = await rpc("push_targets", { p_secret: p.secret, p_event: p.event, p_actor: p.actor || null });
      return json({ sent: await sendAll(targets, messageFor(p.event, p.data || {}), p.event === "urgent") });
    }
    return json({ error: "action inconnue" }, 400);
  } catch (e) {
    return json({ error: String(e && e.message || e) }, 500);
  }
}

if (typeof Deno !== "undefined" && Deno.serve) Deno.serve(handle);
