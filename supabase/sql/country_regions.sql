-- Régions touristiques préconfigurées pour les "grands pays" (V1).
-- Référence : 14 pays "large" (régions obligatoires) + 2 "travel_region" (régions
-- recommandées avec option "Tout le pays" en fallback).
-- Vocabulaire `tags` figé V1 (cf. lib/features/regions/data/region_tags.dart).
--
-- À appliquer une fois dans le SQL editor Supabase. Le client charge les régions
-- via `CountryRegionsRepository` avec fallback JSON asset embarqué + cache 7j.

create table if not exists public.country_regions (
  id                     bigserial   primary key,
  country_code           text        not null,    -- ISO 2 (ex: 'US', 'CN')
  country_name           text        not null,    -- nom FR du pays
  region_name            text        not null,    -- nom FR de la région
  label                  text        not null,    -- villes/lieux principaux (sous-titre carte)
  priority               int         not null,    -- 1-5, ordre d'affichage des cartes
  recommended_radius_km  int         not null,    -- rayon par défaut pour cette région
  tags                   text[]      not null,    -- vocabulaire figé V1
  created_at             timestamptz not null default now(),
  unique (country_code, region_name)
);

create index if not exists country_regions_country_idx
  on public.country_regions (country_code, priority);

-- RLS : lecture pour tous (authenticated + anon), pas d'écriture côté client.
-- Les régions sont seedées via cette migration (et mises à jour par admin/dev).
alter table public.country_regions enable row level security;

create policy "country_regions_read_all"
  on public.country_regions for select
  to anon, authenticated
  using (true);

-- Seed des 80 régions (16 pays × 5).
insert into public.country_regions
  (country_code, country_name, region_name, label, priority, recommended_radius_km, tags)
values
  -- États-Unis (large)
  ('US', 'États-Unis', 'New York & Côte Est', 'New York, Boston, Washington DC, Philadelphie', 1, 350, '{city,culture,first_time,food,shopping}'),
  ('US', 'États-Unis', 'Californie', 'Los Angeles, San Francisco, San Diego, Big Sur', 2, 550, '{city,roadtrip,coast,shopping,food}'),
  ('US', 'États-Unis', 'Ouest américain', 'Las Vegas, Grand Canyon, Utah, Arizona', 3, 700, '{nature,roadtrip,parks,adventure}'),
  ('US', 'États-Unis', 'Floride', 'Miami, Orlando, Keys, Everglades', 4, 450, '{beach,family,theme_parks,nature}'),
  ('US', 'États-Unis', 'Hawaï', 'Oahu, Maui, Big Island, Kauai', 5, 350, '{beach,nature,honeymoon,relax}'),

  -- Chine (large)
  ('CN', 'Chine', 'Shanghai & villages d''eau', 'Shanghai, Suzhou, Hangzhou, Wuzhen', 1, 180, '{city,food,shopping,culture,first_time}'),
  ('CN', 'Chine', 'Pékin & Grande Muraille', 'Pékin, Mutianyu, Tianjin', 2, 200, '{history,culture,monuments,first_time}'),
  ('CN', 'Chine', 'Yunnan', 'Kunming, Dali, Lijiang, Shangri-La', 3, 450, '{nature,villages,authentic,slow_travel}'),
  ('CN', 'Chine', 'Sichuan', 'Chengdu, Leshan, Emeishan, Jiuzhaigou', 4, 450, '{food,nature,pandas,culture}'),
  ('CN', 'Chine', 'Guilin & Yangshuo', 'Guilin, Yangshuo, Longji Rice Terraces', 5, 180, '{nature,landscape,river,photo}'),

  -- Brésil (large)
  ('BR', 'Brésil', 'Rio & Costa Verde', 'Rio de Janeiro, Ilha Grande, Paraty, Angra dos Reis', 1, 350, '{beach,city,nature,first_time}'),
  ('BR', 'Brésil', 'São Paulo & Sudeste', 'São Paulo, Campos do Jordão, Ilhabela', 2, 350, '{city,food,culture,shopping}'),
  ('BR', 'Brésil', 'Bahia', 'Salvador, Praia do Forte, Chapada Diamantina', 3, 500, '{culture,beach,music,nature}'),
  ('BR', 'Brésil', 'Nordeste plages', 'Recife, Porto de Galinhas, Natal, Jericoacoara', 4, 700, '{beach,relax,kitesurf,sun}'),
  ('BR', 'Brésil', 'Amazonie', 'Manaus, Rio Negro, lodges amazoniens', 5, 600, '{nature,wildlife,adventure}'),

  -- Inde (large)
  ('IN', 'Inde', 'Rajasthan & Agra', 'Jaipur, Udaipur, Jodhpur, Jaisalmer, Agra', 1, 650, '{culture,history,palaces,first_time}'),
  ('IN', 'Inde', 'Delhi & Nord classique', 'Delhi, Agra, Varanasi, Rishikesh', 2, 650, '{culture,spiritual,history}'),
  ('IN', 'Inde', 'Kerala', 'Kochi, Alleppey, Munnar, Varkala', 3, 400, '{nature,wellness,beach,slow_travel}'),
  ('IN', 'Inde', 'Goa & Karnataka', 'Goa, Hampi, Gokarna, Mysore', 4, 500, '{beach,relax,culture}'),
  ('IN', 'Inde', 'Himalaya indien', 'Ladakh, Manali, Dharamshala, Shimla', 5, 700, '{mountain,nature,adventure}'),

  -- Australie (large)
  ('AU', 'Australie', 'Sydney & Nouvelle-Galles du Sud', 'Sydney, Blue Mountains, Hunter Valley, Byron Bay', 1, 500, '{city,beach,nature,first_time}'),
  ('AU', 'Australie', 'Melbourne & Victoria', 'Melbourne, Great Ocean Road, Phillip Island', 2, 450, '{city,food,roadtrip,coast}'),
  ('AU', 'Australie', 'Queensland', 'Brisbane, Gold Coast, Cairns, Grande Barrière de Corail', 3, 900, '{beach,nature,diving,family}'),
  ('AU', 'Australie', 'Outback & Centre rouge', 'Uluru, Alice Springs, Kings Canyon', 4, 800, '{desert,nature,adventure}'),
  ('AU', 'Australie', 'Australie Occidentale', 'Perth, Margaret River, Ningaloo, Broome', 5, 1000, '{roadtrip,nature,beach,wildlife}'),

  -- Canada (large)
  ('CA', 'Canada', 'Québec & Ontario', 'Montréal, Québec, Ottawa, Toronto, Niagara', 1, 700, '{city,culture,nature,first_time}'),
  ('CA', 'Canada', 'Rocheuses canadiennes', 'Calgary, Banff, Jasper, Lake Louise', 2, 450, '{mountain,nature,roadtrip}'),
  ('CA', 'Canada', 'Colombie-Britannique', 'Vancouver, Whistler, Victoria, Vancouver Island', 3, 500, '{nature,city,coast,wildlife}'),
  ('CA', 'Canada', 'Provinces atlantiques', 'Halifax, Cape Breton, New Brunswick, PEI', 4, 700, '{coast,nature,roadtrip}'),
  ('CA', 'Canada', 'Yukon & Grand Nord', 'Whitehorse, Dawson City, Northern Lights', 5, 800, '{adventure,nature,remote}'),

  -- Russie (large)
  ('RU', 'Russie', 'Moscou & Anneau d''or', 'Moscou, Serguiev Possad, Souzdal, Vladimir', 1, 300, '{city,history,culture}'),
  ('RU', 'Russie', 'Saint-Pétersbourg', 'Saint-Pétersbourg, Peterhof, Pushkin', 2, 180, '{culture,museums,architecture}'),
  ('RU', 'Russie', 'Lac Baïkal', 'Irkoutsk, Listvyanka, Olkhon Island', 3, 500, '{nature,lake,adventure}'),
  ('RU', 'Russie', 'Transsibérien', 'Moscou, Kazan, Ekaterinbourg, Novossibirsk, Irkoutsk', 4, 2500, '{train,adventure,long_trip}'),
  ('RU', 'Russie', 'Caucase russe', 'Sotchi, Krasnaïa Poliana, Elbrus', 5, 500, '{mountain,nature,wellness}'),

  -- Argentine (large)
  ('AR', 'Argentine', 'Buenos Aires & Pampas', 'Buenos Aires, Tigre, San Antonio de Areco', 1, 250, '{city,culture,food,first_time}'),
  ('AR', 'Argentine', 'Patagonie', 'El Calafate, El Chaltén, Ushuaia, Bariloche', 2, 1200, '{nature,hiking,glaciers,adventure}'),
  ('AR', 'Argentine', 'Nord-Ouest argentin', 'Salta, Jujuy, Cafayate, Quebrada de Humahuaca', 3, 600, '{landscape,culture,roadtrip}'),
  ('AR', 'Argentine', 'Mendoza & Andes', 'Mendoza, Aconcagua, vignobles', 4, 400, '{wine,mountain,food}'),
  ('AR', 'Argentine', 'Chutes d''Iguazú', 'Puerto Iguazú, parc national Iguazú', 5, 150, '{nature,waterfalls,short_trip}'),

  -- Mexique (large)
  ('MX', 'Mexique', 'Mexico City & Centre', 'Mexico City, Teotihuacan, Puebla, Taxco', 1, 300, '{city,culture,food,first_time}'),
  ('MX', 'Mexique', 'Yucatán & Riviera Maya', 'Cancún, Tulum, Valladolid, Mérida, Chichén Itzá', 2, 400, '{beach,culture,ruins,family}'),
  ('MX', 'Mexique', 'Oaxaca & Chiapas', 'Oaxaca, San Cristóbal, Palenque, Sumidero', 3, 650, '{culture,food,nature,authentic}'),
  ('MX', 'Mexique', 'Baja California', 'Los Cabos, La Paz, Todos Santos', 4, 500, '{beach,whales,roadtrip}'),
  ('MX', 'Mexique', 'Côte Pacifique', 'Puerto Vallarta, Sayulita, Guadalajara', 5, 500, '{beach,relax,food}'),

  -- Indonésie (large)
  ('ID', 'Indonésie', 'Bali & îles proches', 'Bali, Nusa Penida, Lombok, Gili Islands', 1, 250, '{beach,wellness,nature,first_time}'),
  ('ID', 'Indonésie', 'Java culturel', 'Jakarta, Yogyakarta, Borobudur, Bromo', 2, 700, '{culture,volcano,history}'),
  ('ID', 'Indonésie', 'Sumatra', 'Medan, Lake Toba, Bukit Lawang', 3, 600, '{nature,wildlife,adventure}'),
  ('ID', 'Indonésie', 'Komodo & Flores', 'Labuan Bajo, Komodo, Kelimutu', 4, 500, '{nature,diving,adventure}'),
  ('ID', 'Indonésie', 'Sulawesi', 'Makassar, Tana Toraja, Bunaken', 5, 700, '{culture,diving,nature}'),

  -- Arabie saoudite (large)
  ('SA', 'Arabie saoudite', 'Riyad & centre', 'Riyad, Diriyah, Edge of the World', 1, 350, '{city,culture,desert}'),
  ('SA', 'Arabie saoudite', 'Djeddah & mer Rouge', 'Djeddah, Al Balad, côte mer Rouge', 2, 350, '{coast,culture,diving}'),
  ('SA', 'Arabie saoudite', 'AlUla & nord-ouest', 'AlUla, Hegra, oasis, désert', 3, 450, '{desert,history,luxury,nature}'),
  ('SA', 'Arabie saoudite', 'Médine & ouest', 'Médine, Khaybar, Yanbu', 4, 400, '{culture,spiritual,history}'),
  ('SA', 'Arabie saoudite', 'Province orientale', 'Dammam, Al Khobar, Al Ahsa', 5, 400, '{city,oasis,coast}'),

  -- Afrique du Sud (large)
  ('ZA', 'Afrique du Sud', 'Cape Town & Garden Route', 'Cape Town, Stellenbosch, Hermanus, Knysna', 1, 700, '{city,nature,wine,first_time}'),
  ('ZA', 'Afrique du Sud', 'Johannesburg & Kruger', 'Johannesburg, Pretoria, Kruger, Blyde River Canyon', 2, 600, '{safari,nature,history}'),
  ('ZA', 'Afrique du Sud', 'Durban & KwaZulu-Natal', 'Durban, Drakensberg, Hluhluwe', 3, 600, '{beach,mountain,safari}'),
  ('ZA', 'Afrique du Sud', 'Route des vins', 'Stellenbosch, Franschhoek, Paarl', 4, 150, '{wine,food,relax}'),
  ('ZA', 'Afrique du Sud', 'Wild Coast & Eastern Cape', 'Coffee Bay, Addo Elephant Park, Port Elizabeth', 5, 600, '{coast,nature,roadtrip}'),

  -- Algérie (large)
  ('DZ', 'Algérie', 'Alger & côte centre', 'Alger, Tipaza, Blida, Cherchell', 1, 250, '{city,culture,coast}'),
  ('DZ', 'Algérie', 'Oran & ouest', 'Oran, Tlemcen, Mostaganem', 2, 400, '{city,culture,coast}'),
  ('DZ', 'Algérie', 'Constantine & est', 'Constantine, Annaba, Guelma, Timgad', 3, 500, '{history,culture,roman_sites}'),
  ('DZ', 'Algérie', 'Sahara central', 'Ghardaïa, Timimoun, El Menia', 4, 800, '{desert,culture,adventure}'),
  ('DZ', 'Algérie', 'Tassili & Hoggar', 'Djanet, Tamanrasset, Assekrem', 5, 900, '{desert,remote,trekking}'),

  -- Kazakhstan (large)
  ('KZ', 'Kazakhstan', 'Almaty & montagnes', 'Almaty, Shymbulak, Big Almaty Lake, Charyn Canyon', 1, 350, '{mountain,nature,city}'),
  ('KZ', 'Kazakhstan', 'Astana & nord', 'Astana, Burabay, Steppe kazakhe', 2, 400, '{city,nature,culture}'),
  ('KZ', 'Kazakhstan', 'Turkestan & sud', 'Turkestan, Shymkent, Aksu-Zhabagly', 3, 500, '{history,culture,nature}'),
  ('KZ', 'Kazakhstan', 'Caspienne & ouest', 'Aktau, Mangystau, Bozzhyra', 4, 800, '{desert,landscape,roadtrip}'),
  ('KZ', 'Kazakhstan', 'Est Kazakhstan', 'Ust-Kamenogorsk, Altai, Katon-Karagay', 5, 700, '{mountain,nature,remote}'),

  -- Turquie (travel_region)
  ('TR', 'Turquie', 'Istanbul & Marmara', 'Istanbul, Bursa, Îles des Princes', 1, 250, '{city,culture,food,first_time}'),
  ('TR', 'Turquie', 'Cappadoce & Anatolie centrale', 'Göreme, Ürgüp, Kayseri, Konya', 2, 400, '{landscape,culture,balloon}'),
  ('TR', 'Turquie', 'Côte égéenne', 'Izmir, Éphèse, Bodrum, Pamukkale', 3, 550, '{beach,history,roadtrip}'),
  ('TR', 'Turquie', 'Côte méditerranéenne', 'Antalya, Kas, Fethiye, Kekova', 4, 550, '{beach,nature,relax}'),
  ('TR', 'Turquie', 'Est anatolien', 'Van, Kars, Mont Ararat, Ani', 5, 800, '{history,mountain,adventure}'),

  -- Thaïlande (travel_region)
  ('TH', 'Thaïlande', 'Bangkok & centre', 'Bangkok, Ayutthaya, Kanchanaburi, Amphawa', 1, 250, '{city,food,culture,first_time}'),
  ('TH', 'Thaïlande', 'Nord Thaïlande', 'Chiang Mai, Chiang Rai, Pai, Mae Hong Son', 2, 450, '{nature,temples,slow_travel}'),
  ('TH', 'Thaïlande', 'Sud Andaman', 'Phuket, Krabi, Koh Phi Phi, Koh Lanta', 3, 350, '{beach,islands,relax}'),
  ('TH', 'Thaïlande', 'Golfe de Thaïlande', 'Koh Samui, Koh Phangan, Koh Tao', 4, 350, '{beach,diving,islands}'),
  ('TH', 'Thaïlande', 'Isan & est', 'Korat, Ubon Ratchathani, Nong Khai', 5, 500, '{authentic,culture,food}')
on conflict (country_code, region_name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- Champs dédiés sur trips pour mémoriser le pays détecté + la région choisie.
-- Évite de re-fetcher Place Details à chaque ouverture du suggesteur.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.trips
  add column if not exists destination_country_code      text,
  add column if not exists destination_country_name      text,
  add column if not exists destination_kind              text,
  add column if not exists selected_region_id            bigint references public.country_regions(id),
  add column if not exists selected_region_name          text,
  add column if not exists selected_region_radius_km     int;
