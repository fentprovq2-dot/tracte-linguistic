// Edge Function: carrega-osm
// Descarrega d'OpenStreetMap (Overpass) els establiments i serveis amb atenció al públic
// d'un municipi i els desa (o actualitza) a la taula `llocs`.
//
// Ús:  POST /functions/v1/carrega-osm   capçalera  x-clau: <valor de admin_config.carrega_clau>
//      cos opcional: { "municipi": "Girona", "bbox": [sud, oest, nord, est], "grup": "comerc"|"amenitats"|"altres" }
//
// Dades © OpenStreetMap contributors, llicència ODbL.

import { createClient } from "jsr:@supabase/supabase-js@2";

const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://overpass.private.coffee/api/interpreter",
];

const RESTAURACIO = ["restaurant", "cafe", "bar", "pub", "fast_food", "ice_cream", "biergarten", "food_court"];
const SERVEI_PUBLIC = [
  "townhall", "police", "courthouse", "post_office", "library", "hospital", "clinic",
  "social_facility", "community_centre", "fire_station",
];
const SALUT_PRIVADA = ["pharmacy", "dentist", "doctors", "veterinary"];
const FINANCES = ["bank", "bureau_de_change"];
const LLEURE = ["cinema", "theatre", "arts_centre", "nightclub"];

type Tags = Record<string, string>;
type Classificacio = { modalitat: "presencial" | "servei_public"; categoria: string } | null;

function classifica(t: Tags): Classificacio {
  const a = t.amenity, s = t.shop, o = t.office, tu = t.tourism, h = t.healthcare;
  if (o === "government" || (a && SERVEI_PUBLIC.includes(a)) || h === "centre" || h === "hospital") {
    const cat =
      a === "hospital" || a === "clinic" || h ? "salut pública" :
      a === "library" || a === "community_centre" ? "cultura i equipaments" :
      a === "police" || a === "courthouse" || a === "fire_station" ? "seguretat i justícia" :
      a === "post_office" ? "correus" : "administració";
    return { modalitat: "servei_public", categoria: cat };
  }
  if (a && RESTAURACIO.includes(a)) return { modalitat: "presencial", categoria: "restauració" };
  if (a && SALUT_PRIVADA.includes(a)) return { modalitat: "presencial", categoria: "salut i farmàcia" };
  if (a && FINANCES.includes(a)) return { modalitat: "presencial", categoria: "banca i finances" };
  if (a && LLEURE.includes(a)) return { modalitat: "presencial", categoria: "cultura i lleure" };
  if (a === "fuel" || a === "car_rental" || a === "car_wash") return { modalitat: "presencial", categoria: "motor i transport" };
  if (tu && ["hotel", "hostel", "guest_house", "motel", "apartment"].includes(tu))
    return { modalitat: "presencial", categoria: "allotjament" };
  if (tu === "museum" || tu === "information") return { modalitat: "presencial", categoria: "cultura i lleure" };
  if (s) {
    const alimentacio = ["supermarket", "convenience", "bakery", "butcher", "greengrocer", "pastry",
      "deli", "seafood", "confectionery", "alcohol", "beverages", "cheese", "coffee", "tea", "wine", "frozen_food"];
    if (alimentacio.includes(s)) return { modalitat: "presencial", categoria: "alimentació" };
    if (["hairdresser", "beauty", "cosmetics", "massage", "tattoo", "optician", "chemist"].includes(s))
      return { modalitat: "presencial", categoria: "cura personal" };
    if (["clothes", "shoes", "jewelry", "bag", "boutique", "fashion_accessories"].includes(s))
      return { modalitat: "presencial", categoria: "moda" };
    if (["mobile_phone", "computer", "electronics", "telecommunication"].includes(s))
      return { modalitat: "presencial", categoria: "tecnologia i telefonia" };
    return { modalitat: "presencial", categoria: "comerç" };
  }
  if (o) return { modalitat: "presencial", categoria: o === "estate_agent" ? "immobiliària" : "oficines i serveis" };
  if (t.craft) return { modalitat: "presencial", categoria: "oficis" };
  return null;
}

function adreca(t: Tags): string | null {
  const carrer = t["addr:street"], num = t["addr:housenumber"];
  if (!carrer) return null;
  return num ? `${carrer}, ${num}` : carrer;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Mètode no permès", { status: 405 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  // La clau d'administració es desa a la taula admin_config (inaccessible per al públic)
  const { data: cfg } = await db.from("admin_config").select("valor").eq("clau", "carrega_clau").maybeSingle();
  const clau = cfg?.valor;
  if (!clau || req.headers.get("x-clau") !== clau) return new Response("No autoritzat", { status: 401 });

  let municipi = "Girona";
  let bbox: unknown = null;   // [sud, oest, nord, est]
  let grup: unknown = null;   // 'comerc' | 'amenitats' | 'altres' (per defecte, tots)
  try {
    const cos = await req.json();
    if (typeof cos?.municipi === "string" && cos.municipi.trim()) municipi = cos.municipi.trim();
    bbox = cos?.bbox ?? null;
    grup = cos?.grup ?? null;
  } catch { /* cos buit */ }
  // Zona: una capsa (bbox) és molt més ràpida per a Overpass que l'àrea administrativa
  const zona = Array.isArray(bbox) && bbox.length === 4 && bbox.every((x) => typeof x === "number")
    ? bbox.join(",")
    : `area.m`;
  const prefix = zona === "area.m"
    ? `area["boundary"="administrative"]["admin_level"="8"]["name"="${municipi.replace(/"/g, '\\"')}"]->.m;`
    : "";

  // Grups de consulta: es poden demanar per separat per no superar els límits de temps
  const AMENITATS = [...RESTAURACIO, ...SERVEI_PUBLIC, ...SALUT_PRIVADA, ...FINANCES, ...LLEURE, "fuel", "car_rental", "car_wash"];
  const GRUPS: Record<string, string[]> = {
    comerc: [`nwr["name"]["shop"](${zona});`],
    amenitats: [`nwr["name"]["amenity"~"^(${AMENITATS.join("|")})$"](${zona});`],
    altres: [
      `nwr["name"]["office"](${zona});`,
      `nwr["name"]["craft"](${zona});`,
      `nwr["name"]["tourism"~"^(hotel|hostel|guest_house|motel|apartment|museum|information)$"](${zona});`,
      `nwr["name"]["healthcare"](${zona});`,
    ],
  };
  const grups = typeof grup === "string" && GRUPS[grup] ? [grup] : Object.keys(GRUPS);
  const consulta = `
[out:json][timeout:120];
${prefix}
(
  ${grups.flatMap((g) => GRUPS[g]).join("\n  ")}
);
out center tags qt;`;

  // Prova la instància principal i, si falla, dues rèpliques públiques
  let dades: { elements?: any[] } | null = null;
  const errors: string[] = [];
  for (const url of OVERPASS) {
    try {
      const r = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "application/json, */*",
          "User-Agent": "TracteLinguistic/0.1 (prototip; https://github.com/)",
        },
        body: "data=" + encodeURIComponent(consulta),
        signal: AbortSignal.timeout(65_000),
      });
      console.log(`Overpass ${new URL(url).host}: ${r.status}`);
      if (!r.ok) { errors.push(`${new URL(url).host}: ${r.status} ${(await r.text()).slice(0, 200)}`); continue; }
      dades = await r.json();
      break;
    } catch (e) { errors.push(`${new URL(url).host}: ${(e as Error).message}`); }
  }
  if (!dades) return new Response(JSON.stringify({ error: "Overpass no disponible", errors }), { status: 502 });

  const files: Record<string, unknown>[] = [];
  let descartats = 0;
  for (const e of dades.elements ?? []) {
    const t: Tags = e.tags ?? {};
    if (t["disused:shop"] || t["disused:amenity"] || t.opening_hours === "closed") { descartats++; continue; }
    const c = classifica(t);
    const lat = e.lat ?? e.center?.lat, lon = e.lon ?? e.center?.lon;
    if (!c || lat == null || lon == null) { descartats++; continue; }
    files.push({
      nom: (t["name:ca"] || t.name).slice(0, 120),
      modalitat: c.modalitat,
      categoria: c.categoria,
      municipi: t["addr:city"] || municipi,
      adreca: adreca(t),
      lat, lon,
      font: "osm",
      font_id: `${e.type}/${e.id}`,
    });
  }

  let desats = 0;
  for (let i = 0; i < files.length; i += 500) {
    const lot = files.slice(i, i + 500);
    const { error } = await db.from("llocs").upsert(lot, { onConflict: "font,font_id" });
    if (error) return new Response(JSON.stringify({ error: error.message, desats }), { status: 500 });
    desats += lot.length;
  }

  return new Response(JSON.stringify({ municipi, rebuts: dades.elements?.length ?? 0, desats, descartats }), {
    headers: { "Content-Type": "application/json" },
  });
});
