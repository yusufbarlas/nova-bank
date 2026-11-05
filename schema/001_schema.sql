-- =====================================================================
-- Nova Dijital Bank — schema/001_schema.sql
-- Amaç     : Projenin bütün tablolarını, ilişkilerini ve kısıtlarını kurar.
-- Çalıştır : DBeaver'da "novabank (Docker)" bağlantısında, bütün script: Alt + X
-- Not      : Dosya baştan çalıştırılabilir; önce eski tabloları siler.
--            Bu yüzden sadece geliştirme ortamında kullanılır.
-- Kurallar : Hiçbir kayıt silinmez (ON DELETE RESTRICT), para NUMERIC(14,2),
--            saatli olaylar TIMESTAMPTZ, kimlikler GENERATED ALWAYS AS IDENTITY.
-- =====================================================================

BEGIN;  -- Hepsi tek transaction: bir yerde hata olursa hiçbir şey kurulmaz.

-- ---------------------------------------------------------------------
-- 0. Saat dilimi
-- Gün hesapları (islem_zamani::date) bağlantının saat dilimine göre değişir.
-- Veritabanı varsayılanı İstanbul olsun ki herkes aynı günü görsün.
-- ALTER DATABASE yeni bağlantılarda geçerli olur; SET bu oturum için.
-- ---------------------------------------------------------------------
ALTER DATABASE novabank SET timezone TO 'Europe/Istanbul';
SET timezone TO 'Europe/Istanbul';

-- ---------------------------------------------------------------------
-- 1. Temizlik: tablolar varsa sil (yeniden kurulum için)
-- CASCADE: bu tablolara bağlı FK kısıtlarını da kaldırır.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS
    kredi_taksitleri, krediler,
    kart_harcamalari, kampanya_hedefleri, kampanyalar, kart_ekstreleri, kartlar,
    dijital_aktivite, islemler,
    referans_faizler, doviz_kurlari, hesaplar, dijital_basvurular, musteriler,
    subeler, isyeri_kategorileri, islem_turleri, bankalar
CASCADE;

-- =====================================================================
-- GRUP 1 · Referans tabloları
-- =====================================================================

-- 1 · Bankalar: dış transferlerde karşı banka. Bir satır = bir banka.
CREATE TABLE bankalar (
    banka_kodu  TEXT PRIMARY KEY,               -- doğal anahtar: 'B01'
    banka_adi   TEXT NOT NULL UNIQUE
);

-- 2 · İşlem türleri. Bir satır = bir işlem türü.
CREATE TABLE islem_turleri (
    islem_turu_kodu  TEXT PRIMARY KEY,          -- 'MAAS', 'FAST' ...
    islem_turu_adi   TEXT NOT NULL UNIQUE,
    yon_kurali       TEXT NOT NULL,             -- bu tür hangi yönde olabilir
    CONSTRAINT ck_islem_turleri_yon_kurali
        CHECK (yon_kurali IN ('giris', 'cikis', 'ikisi'))
);

-- 3 · Harcama kategorileri. Bir satır = bir kategori.
CREATE TABLE isyeri_kategorileri (
    kategori_kodu  TEXT PRIMARY KEY,            -- 'MARKET' ...
    kategori_adi   TEXT NOT NULL UNIQUE
);

-- 4 · Şubeler (kendine bağlı: şube → bölge → genel müdürlük).
CREATE TABLE subeler (
    sube_id       INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sube_adi      TEXT NOT NULL UNIQUE,
    birim_turu    TEXT NOT NULL,
    sehir         TEXT NOT NULL,
    ust_birim_id  INTEGER REFERENCES subeler (sube_id) ON DELETE RESTRICT,  -- genel müdürlükte NULL
    CONSTRAINT ck_subeler_birim_turu
        CHECK (birim_turu IN ('genel_mudurluk', 'bolge', 'sube', 'dijital'))
);

-- =====================================================================
-- GRUP 2 · Müşteri ve hesap
-- =====================================================================

-- 5 · Müşteriler. Bir satır = bir müşteri.
CREATE TABLE musteriler (
    musteri_id      INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ad              TEXT NOT NULL,
    soyad           TEXT NOT NULL,
    dogum_tarihi    DATE NOT NULL,
    sehir           TEXT NOT NULL,
    edinim_kanali   TEXT NOT NULL,
    kayit_tarihi    DATE NOT NULL,
    risk_profili    SMALLINT,                   -- yatırım modülü için yer tutucu
    durum           TEXT NOT NULL DEFAULT 'acik',
    kapanis_tarihi  DATE,
    CONSTRAINT ck_musteriler_edinim_kanali
        CHECK (edinim_kanali IN ('mobil', 'web', 'sube')),
    CONSTRAINT ck_musteriler_en_az_18_yas
        CHECK (dogum_tarihi <= kayit_tarihi - INTERVAL '18 years'),
    CONSTRAINT ck_musteriler_risk_profili
        CHECK (risk_profili BETWEEN 1 AND 5),
    CONSTRAINT ck_musteriler_durum
        CHECK (durum IN ('acik', 'kapali')),
    -- kapalı ⇔ kapanış tarihi dolu; kapanış kayıttan önce olamaz
    CONSTRAINT ck_musteriler_kapanis
        CHECK ((durum = 'kapali') = (kapanis_tarihi IS NOT NULL)
               AND (kapanis_tarihi IS NULL OR kapanis_tarihi >= kayit_tarihi))
);

-- 6 · Dijital başvurular. Bir satır = bir başvuru.
CREATE TABLE dijital_basvurular (
    basvuru_id               INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    indirme_tarihi           DATE NOT NULL,
    kimlik_dogrulama_tarihi  DATE,              -- NULL = bu adımda kaldı
    onay_tarihi              DATE,
    red_nedeni               TEXT,
    musteri_id               INTEGER UNIQUE      -- UNIQUE: bir başvurudan en fazla bir müşteri (1-1)
                             REFERENCES musteriler (musteri_id) ON DELETE RESTRICT,
    CONSTRAINT ck_basvuru_dogrulama_sirasi
        CHECK (kimlik_dogrulama_tarihi IS NULL OR kimlik_dogrulama_tarihi >= indirme_tarihi),
    CONSTRAINT ck_basvuru_onay_sirasi
        CHECK (onay_tarihi IS NULL
               OR (kimlik_dogrulama_tarihi IS NOT NULL AND onay_tarihi >= kimlik_dogrulama_tarihi)),
    CONSTRAINT ck_basvuru_onay_veya_red
        CHECK (NOT (onay_tarihi IS NOT NULL AND red_nedeni IS NOT NULL))
);

-- 7 · Hesaplar. Bir satır = bir hesap. Müşteri 1-N hesap.
CREATE TABLE hesaplar (
    hesap_id        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    musteri_id      INTEGER NOT NULL REFERENCES musteriler (musteri_id) ON DELETE RESTRICT,
    sube_id         INTEGER NOT NULL REFERENCES subeler (sube_id) ON DELETE RESTRICT,
    hesap_turu      TEXT NOT NULL,
    para_birimi     TEXT NOT NULL,
    faiz_orani      NUMERIC(5,2),               -- yıllık %, sadece vadeli
    acilis_tarihi   DATE NOT NULL,
    durum           TEXT NOT NULL DEFAULT 'acik',
    kapanis_tarihi  DATE,
    CONSTRAINT ck_hesaplar_hesap_turu
        CHECK (hesap_turu IN ('vadesiz', 'vadeli')),
    CONSTRAINT ck_hesaplar_para_birimi
        CHECK (para_birimi IN ('TRY', 'USD', 'EUR')),
    -- vadeli ⇔ faiz oranı dolu; oran pozitif
    CONSTRAINT ck_hesaplar_faiz
        CHECK ((hesap_turu = 'vadeli') = (faiz_orani IS NOT NULL)
               AND (faiz_orani IS NULL OR faiz_orani > 0)),
    CONSTRAINT ck_hesaplar_durum
        CHECK (durum IN ('acik', 'kapali')),
    CONSTRAINT ck_hesaplar_kapanis
        CHECK ((durum = 'kapali') = (kapanis_tarihi IS NOT NULL)
               AND (kapanis_tarihi IS NULL OR kapanis_tarihi >= acilis_tarihi))
);

-- 8 · Döviz kurları. Bir satır = bir gün × bir döviz. Bileşik PK.
CREATE TABLE doviz_kurlari (
    tarih        DATE NOT NULL,
    para_birimi  TEXT NOT NULL,
    kur_try      NUMERIC(10,4) NOT NULL,        -- 1 birimin TL karşılığı
    PRIMARY KEY (tarih, para_birimi),
    CONSTRAINT ck_kurlar_para_birimi CHECK (para_birimi IN ('USD', 'EUR')),
    CONSTRAINT ck_kurlar_pozitif     CHECK (kur_try > 0)
);

-- 9 · Referans faizler (FTP). Bir satır = bir ay.
CREATE TABLE referans_faizler (
    ay           DATE PRIMARY KEY,
    yillik_oran  NUMERIC(5,2) NOT NULL,         -- yıllık %
    CONSTRAINT ck_ref_faiz_ayin_ilk_gunu CHECK (ay = date_trunc('month', ay)::date),
    CONSTRAINT ck_ref_faiz_pozitif       CHECK (yillik_oran > 0)
);

-- =====================================================================
-- GRUP 3 · Hareketler
-- =====================================================================

-- 10 · İşlemler (hesap defteri). Bir satır = bir hesaptaki bir para hareketi.
CREATE TABLE islemler (
    islem_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hesap_id          INTEGER NOT NULL REFERENCES hesaplar (hesap_id) ON DELETE RESTRICT,
    islem_zamani      TIMESTAMPTZ NOT NULL,
    islem_turu_kodu   TEXT NOT NULL REFERENCES islem_turleri (islem_turu_kodu) ON DELETE RESTRICT,
    yon               TEXT NOT NULL,
    tutar             NUMERIC(14,2) NOT NULL,   -- hesabın kendi para biriminde, hep pozitif
    kanal             TEXT NOT NULL,
    karsi_hesap_id    INTEGER REFERENCES hesaplar (hesap_id) ON DELETE RESTRICT,     -- banka içi transfer
    karsi_banka_kodu  TEXT REFERENCES bankalar (banka_kodu) ON DELETE RESTRICT,     -- dış transfer
    kendi_hesabina    BOOLEAN,                  -- sadece dış transferde dolu
    otomatik_talimat  BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT ck_islemler_yon    CHECK (yon IN ('giris', 'cikis')),
    CONSTRAINT ck_islemler_tutar  CHECK (tutar > 0),
    CONSTRAINT ck_islemler_kanal  CHECK (kanal IN ('mobil', 'internet', 'atm', 'sube', 'sistem')),
    -- bir transfer ya içeridir ya dışarı, ikisi birden olamaz
    CONSTRAINT ck_islemler_karsi_taraf
        CHECK (karsi_hesap_id IS NULL OR karsi_banka_kodu IS NULL),
    -- hesap kendine transfer yapamaz
    CONSTRAINT ck_islemler_kendine_transfer
        CHECK (karsi_hesap_id IS NULL OR karsi_hesap_id <> hesap_id),
    CONSTRAINT ck_islemler_kendi_hesabina
        CHECK (kendi_hesabina IS NULL OR karsi_banka_kodu IS NOT NULL),
    CONSTRAINT ck_islemler_otomatik_talimat
        CHECK (NOT otomatik_talimat OR islem_turu_kodu = 'FATURA')
);

-- 11 · Dijital aktivite (günlük özet). Bir satır = bir müşteri × bir gün.
-- Satırı olmayan gün = 0 giriş.
CREATE TABLE dijital_aktivite (
    musteri_id    INTEGER NOT NULL REFERENCES musteriler (musteri_id) ON DELETE RESTRICT,
    tarih         DATE NOT NULL,
    giris_sayisi  SMALLINT NOT NULL,
    PRIMARY KEY (musteri_id, tarih),
    CONSTRAINT ck_dijital_aktivite_giris CHECK (giris_sayisi > 0)
);

-- =====================================================================
-- GRUP 4 · Kart ve kampanya
-- =====================================================================

-- 12 · Kartlar. Bir satır = bir kart.
CREATE TABLE kartlar (
    kart_id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    musteri_id         INTEGER NOT NULL REFERENCES musteriler (musteri_id) ON DELETE RESTRICT,
    hesap_id           INTEGER REFERENCES hesaplar (hesap_id) ON DELETE RESTRICT,
    kart_turu          TEXT NOT NULL,
    kart_limiti        NUMERIC(14,2),           -- bugünkü limit ("limit" SQL'de ayrılmış kelime)
    basvuru_tarihi     DATE NOT NULL,
    aktivasyon_tarihi  DATE,                    -- NULL = hiç aktive edilmedi
    durum              TEXT NOT NULL DEFAULT 'acik',
    kapanis_tarihi     DATE,
    CONSTRAINT ck_kartlar_kart_turu CHECK (kart_turu IN ('banka', 'kredi')),
    CONSTRAINT ck_kartlar_banka_karti_hesap
        CHECK (kart_turu <> 'banka' OR hesap_id IS NOT NULL),
    CONSTRAINT ck_kartlar_limit
        CHECK ((kart_turu = 'kredi' AND kart_limiti IS NOT NULL AND kart_limiti > 0)
            OR (kart_turu = 'banka' AND kart_limiti IS NULL)),
    CONSTRAINT ck_kartlar_aktivasyon
        CHECK (aktivasyon_tarihi IS NULL OR aktivasyon_tarihi >= basvuru_tarihi),
    CONSTRAINT ck_kartlar_durum CHECK (durum IN ('acik', 'kapali')),
    CONSTRAINT ck_kartlar_kapanis
        CHECK ((durum = 'kapali') = (kapanis_tarihi IS NOT NULL)
               AND (kapanis_tarihi IS NULL OR kapanis_tarihi >= basvuru_tarihi))
);

-- 13 · Kart ekstreleri. Bir satır = bir kredi kartının bir aylık ekstresi.
-- Ekstre o ayın fotoğrafıdır: o ayki limiti (donem_limiti) kendi içinde taşır.
CREATE TABLE kart_ekstreleri (
    kart_id              INTEGER NOT NULL REFERENCES kartlar (kart_id) ON DELETE RESTRICT,
    donem                DATE NOT NULL,         -- ayın ilk günü
    kesim_tarihi         DATE NOT NULL,
    son_odeme_tarihi     DATE NOT NULL,
    donem_limiti         NUMERIC(14,2) NOT NULL,
    ekstre_borcu         NUMERIC(14,2) NOT NULL,
    asgari_tutar         NUMERIC(14,2) NOT NULL,
    odenen_tutar         NUMERIC(14,2) NOT NULL DEFAULT 0,
    asgari_odeme_tarihi  DATE,                  -- NULL = asgari ödenmedi
    PRIMARY KEY (kart_id, donem),
    CONSTRAINT ck_ekstre_donem_ilk_gun   CHECK (donem = date_trunc('month', donem)::date),
    CONSTRAINT ck_ekstre_tarih_sirasi    CHECK (son_odeme_tarihi > kesim_tarihi),
    CONSTRAINT ck_ekstre_limit           CHECK (donem_limiti > 0),
    CONSTRAINT ck_ekstre_borc            CHECK (ekstre_borcu >= 0),
    CONSTRAINT ck_ekstre_asgari          CHECK (asgari_tutar >= 0 AND asgari_tutar <= ekstre_borcu),
    CONSTRAINT ck_ekstre_odenen          CHECK (odenen_tutar >= 0),
    CONSTRAINT ck_ekstre_odeme_tarihi
        CHECK (asgari_odeme_tarihi IS NULL OR asgari_odeme_tarihi >= kesim_tarihi),
    -- asgari 0 ise (borç yok) ödenmiş sayılır, tarihi dolu olmalı
    CONSTRAINT ck_ekstre_asgari_sifir
        CHECK (asgari_tutar > 0 OR asgari_odeme_tarihi IS NOT NULL)
);

-- 14 · Kampanyalar. Bir satır = bir kampanya.
CREATE TABLE kampanyalar (
    kampanya_id    INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kampanya_adi   TEXT NOT NULL,
    kategori_kodu  TEXT NOT NULL REFERENCES isyeri_kategorileri (kategori_kodu) ON DELETE RESTRICT,
    indirim_orani  NUMERIC(5,2) NOT NULL,       -- bankanın verdiği puan / iade, %
    baslangic      DATE NOT NULL,
    bitis          DATE NOT NULL,
    CONSTRAINT ck_kampanya_indirim CHECK (indirim_orani > 0 AND indirim_orani < 100),
    CONSTRAINT ck_kampanya_tarih   CHECK (bitis >= baslangic)
);

-- 15 · Kampanya hedefleri (çoka çok ilişkinin ara tablosu).
-- Bir satır = bir kampanya × bir müşteri. İlişkinin kendi bilgisi: grup, atama tarihi.
CREATE TABLE kampanya_hedefleri (
    kampanya_id   INTEGER NOT NULL REFERENCES kampanyalar (kampanya_id) ON DELETE RESTRICT,
    musteri_id    INTEGER NOT NULL REFERENCES musteriler (musteri_id) ON DELETE RESTRICT,
    grup          TEXT NOT NULL,
    atama_tarihi  DATE NOT NULL,
    PRIMARY KEY (kampanya_id, musteri_id),      -- aynı müşteri aynı kampanyaya iki kez atanamaz
    CONSTRAINT ck_kampanya_hedefleri_grup CHECK (grup IN ('hedef', 'kontrol'))
);

-- 16 · Kart harcamaları (kart ayrıntısı). Bir satır = bir kart harcaması.
-- Banka kartı harcamasının hesaptan çıkışı islemler'de; islem_id onu gösterir.
CREATE TABLE kart_harcamalari (
    harcama_id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kart_id               INTEGER NOT NULL REFERENCES kartlar (kart_id) ON DELETE RESTRICT,
    harcama_zamani        TIMESTAMPTZ NOT NULL,
    tutar                 NUMERIC(14,2) NOT NULL,   -- TL
    kategori_kodu         TEXT NOT NULL REFERENCES isyeri_kategorileri (kategori_kodu) ON DELETE RESTRICT,
    kampanya_id           INTEGER REFERENCES kampanyalar (kampanya_id) ON DELETE RESTRICT,
    indirim_tutari        NUMERIC(14,2) NOT NULL DEFAULT 0,   -- bankanın maliyeti
    taksit_sayisi         SMALLINT NOT NULL DEFAULT 1,
    uye_isyeri_komisyonu  NUMERIC(14,2) NOT NULL,   -- bankanın geliri
    islem_id              BIGINT UNIQUE REFERENCES islemler (islem_id) ON DELETE RESTRICT,
    CONSTRAINT ck_harcama_tutar     CHECK (tutar > 0),
    CONSTRAINT ck_harcama_indirim   CHECK (indirim_tutari >= 0),
    CONSTRAINT ck_harcama_kampanyasiz_indirim
        CHECK (kampanya_id IS NOT NULL OR indirim_tutari = 0),
    CONSTRAINT ck_harcama_taksit    CHECK (taksit_sayisi BETWEEN 1 AND 12),
    CONSTRAINT ck_harcama_komisyon  CHECK (uye_isyeri_komisyonu >= 0)
);

-- =====================================================================
-- GRUP 5 · Kredi (bu sürümde analizi yok; şemada hazır)
-- =====================================================================

-- 17 · Krediler. Bir satır = bir kredi.
CREATE TABLE krediler (
    kredi_id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    musteri_id          INTEGER NOT NULL REFERENCES musteriler (musteri_id) ON DELETE RESTRICT,
    hesap_id            INTEGER NOT NULL REFERENCES hesaplar (hesap_id) ON DELETE RESTRICT,
    kredi_turu          TEXT NOT NULL,
    anapara             NUMERIC(14,2) NOT NULL,
    faiz_orani          NUMERIC(5,2) NOT NULL,  -- yıllık %
    vade_ay             SMALLINT NOT NULL,
    kullandirim_tarihi  DATE NOT NULL,
    durum               TEXT NOT NULL DEFAULT 'acik',
    CONSTRAINT ck_krediler_tur     CHECK (kredi_turu IN ('ihtiyac', 'tasit', 'konut')),
    CONSTRAINT ck_krediler_anapara CHECK (anapara > 0),
    CONSTRAINT ck_krediler_faiz    CHECK (faiz_orani > 0),
    CONSTRAINT ck_krediler_vade    CHECK (vade_ay BETWEEN 1 AND 120),
    CONSTRAINT ck_krediler_durum   CHECK (durum IN ('acik', 'kapali'))
);

-- 18 · Kredi taksitleri. Bir satır = bir kredinin bir taksiti. Bileşik PK.
CREATE TABLE kredi_taksitleri (
    kredi_id        INTEGER NOT NULL REFERENCES krediler (kredi_id) ON DELETE RESTRICT,
    taksit_no       SMALLINT NOT NULL,
    vade_tarihi     DATE NOT NULL,
    anapara_tutari  NUMERIC(14,2) NOT NULL,
    faiz_tutari     NUMERIC(14,2) NOT NULL,
    odeme_tarihi    DATE,                       -- NULL = ödenmedi
    PRIMARY KEY (kredi_id, taksit_no),
    CONSTRAINT ck_taksit_no      CHECK (taksit_no >= 1),
    CONSTRAINT ck_taksit_tutarlar CHECK (anapara_tutari >= 0 AND faiz_tutari >= 0)
);

-- =====================================================================
-- Referans verileri (sabit listeler; hayali banka adları)
-- =====================================================================

INSERT INTO bankalar (banka_kodu, banka_adi) VALUES
    ('B01', 'Pusula Bank'),
    ('B02', 'Kuzey Bank'),
    ('B03', 'Liman Bank'),
    ('B04', 'Defne Bank'),
    ('B05', 'Ege Yıldız Bank');

INSERT INTO islem_turleri (islem_turu_kodu, islem_turu_adi, yon_kurali) VALUES
    ('MAAS',             'Maaş yatışı',                            'giris'),
    ('PARA_YATIRMA',     'Para yatırma',                           'giris'),
    ('PARA_CEKME',       'Para çekme',                             'cikis'),
    ('HAVALE',           'Havale (banka içi)',                     'ikisi'),
    ('EFT',              'EFT',                                    'ikisi'),
    ('FAST',             'FAST',                                   'ikisi'),
    ('FATURA',           'Fatura ödemesi',                         'cikis'),
    ('FAIZ',             'Mevduat faizi ödemesi',                  'giris'),
    ('KART_HARCAMA',     'Banka kartı harcaması',                  'cikis'),
    ('KART_BORCU_IC',    'Nova kredi kartı borcu ödemesi',         'cikis'),
    ('KART_BORCU_DIS',   'Başka banka kredi kartı borcu ödemesi',  'cikis'),
    ('KREDI_TAKSIT_DIS', 'Başka bankaya kredi taksiti ödemesi',    'cikis');

INSERT INTO isyeri_kategorileri (kategori_kodu, kategori_adi) VALUES
    ('MARKET',     'Market'),
    ('AKARYAKIT',  'Akaryakıt'),
    ('ETICARET',   'E-ticaret'),
    ('RESTORAN',   'Restoran ve kafe'),
    ('SEYAHAT',    'Seyahat'),
    ('GIYIM',      'Giyim'),
    ('ELEKTRONIK', 'Elektronik'),
    ('EGITIM',     'Eğitim'),
    ('SAGLIK',     'Sağlık');

COMMIT;
