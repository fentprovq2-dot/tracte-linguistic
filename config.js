// Configuració del client. Les dues claus són públiques per disseny (clau "publishable"):
// la seguretat la garanteixen les polítiques RLS i les funcions de la base de dades.
// Mentre quedin buides, l'aplicació funciona en MODE DEMOSTRACIÓ amb dades fictícies.
window.TRACTE_CONFIG = {
  supabaseUrl: "https://vgqmugrnkrsoynuojoda.supabase.co",
  supabaseKey: "sb_publishable_zqsxq7m-bCwQ1gR9qZLCeA_EGD3E_5b",
  centre: [41.9794, 2.8214], // Girona
  zoom: 15,
};
