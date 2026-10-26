// Configuració del client. Les claus de Supabase són públiques per disseny (clau "publishable"):
// la seguretat la garanteixen les polítiques RLS i les funcions de la base de dades.
// Si supabaseUrl o supabaseKey queden buides, l'aplicació funciona en MODE DEMOSTRACIÓ amb dades fictícies.
window.TRACTE_CONFIG = {
  supabaseUrl: "https://vgqmugrnkrsoynuojoda.supabase.co",
  supabaseKey: "sb_publishable_zqsxq7m-bCwQ1gR9qZLCeA_EGD3E_5b",
  centre: [41.9794, 2.8214], // Girona
  zoom: 15,

  // Mapa de fons: servei Mapa Base de l'Institut Cartogràfic i Geològic de Catalunya (ICGC).
  // Sense clau. Capes disponibles: estandard, estandard-gris, topografic, topografic-gris, simplificat, orto…
  mapa: {
    url: "https://geoserveis.icgc.cat/servei/catalunya/mapa-base/wmts/estandard-gris/MON3857NW/{z}/{x}/{y}.png",
    attribution: '&copy; <a href="https://www.icgc.cat/" target="_blank" rel="noopener">ICGC</a> (CC BY) · &copy; <a href="https://openmaptiles.org/" target="_blank" rel="noopener">OpenMapTiles</a> · &copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">col·laboradors d\'OpenStreetMap</a>',
    maxZoom: 19,
  },
};
