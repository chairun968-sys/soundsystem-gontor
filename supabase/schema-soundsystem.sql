-- =============================================================================
-- SKEMA DATABASE SUPABASE: SISTEM INVENTARIS & PEMINJAMAN SOUND SYSTEM
-- PONDOK MODERN DARUSSALAM GONTOR KAMPUS 4 BANYUWANGI
-- =============================================================================

-- Aktifkan ekstensi UUID
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- -----------------------------------------------------------------------------
-- 1. TABEL PROFIL PENGGUNA (ROLE-BASED ACCESS CONTROL)
-- Role:
--  - 'admin_gudang' : Akses penuh scan QR, transaksi checkout/checkin, CRUD alat.
--  - 'pimpinan'     : Akses dashboard eksekutif, audit traceability, unduh laporan.
--  - 'peminjam'     : Akses publik melihat stok ready & booking jadwal.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS snd_profil (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nama TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'admin_gudang' CHECK (role IN ('admin_gudang', 'pimpinan', 'peminjam')),
  bagian TEXT DEFAULT 'Bagian Sound System & Acara Gontor 4',
  no_wa TEXT,
  aktif BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 2. TABEL MASTER KATEGORI & LOKASI PENYIMPANAN
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS snd_kategori (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nama TEXT NOT NULL UNIQUE,
  kode_prefix TEXT NOT NULL UNIQUE, -- Cth: 'SPK', 'MIC', 'MIX', 'KBL', 'STD'
  deskripsi TEXT,
  urutan INT DEFAULT 1,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS snd_lokasi (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nama_zona TEXT NOT NULL, -- Cth: 'Zona A - Speaker Utama'
  kode_rak TEXT NOT NULL,  -- Cth: 'RAK-A01'
  keterangan TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 3. TABEL MASTER INVENTARIS PERANGKAT SOUND (ASET)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS snd_aset (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  kode_unik TEXT NOT NULL UNIQUE, -- Cth: 'SPK-ACT-01', 'MIC-WL-01'
  nama TEXT NOT NULL,
  merk TEXT NOT NULL,
  kategori_id UUID REFERENCES snd_kategori(id) ON DELETE SET NULL,
  lokasi_id UUID REFERENCES snd_lokasi(id) ON DELETE SET NULL,
  tahun_pengadaan INT DEFAULT EXTRACT(YEAR FROM CURRENT_DATE),
  nomor_seri TEXT,
  kondisi TEXT NOT NULL DEFAULT 'baik' CHECK (kondisi IN ('baik', 'rusak_ringan', 'rusak_berat')),
  status TEXT NOT NULL DEFAULT 'tersedia' CHECK (status IN ('tersedia', 'dipinjam', 'servis', 'afkir')),
  foto_url TEXT,
  qr_payload TEXT NOT NULL, -- Cth: 'GONTOR4-SOUND-SPK-ACT-01'
  spesifikasi JSONB DEFAULT '{}'::jsonb, -- Daya watt, channel, kabel meter dsb
  peminjam_terakhir TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 4. TABEL MODE PAKET (BUNDLING STANDAR ACARA)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS snd_paket (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  kode_paket TEXT NOT NULL UNIQUE, -- Cth: 'PKT-MUHADHOROH-01'
  nama_paket TEXT NOT NULL,        -- Cth: 'Paket Muhadhoroh Akbar'
  deskripsi TEXT,
  qr_induk TEXT NOT NULL UNIQUE,
  aktif BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS snd_paket_item (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  paket_id UUID REFERENCES snd_paket(id) ON DELETE CASCADE,
  aset_id UUID REFERENCES snd_aset(id) ON DELETE CASCADE,
  jumlah INT DEFAULT 1,
  UNIQUE(paket_id, aset_id)
);

-- -----------------------------------------------------------------------------
-- 5. TABEL TRANSAKSI PEMINJAMAN (CHECK-OUT)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS snd_peminjaman (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  kode_transaksi TEXT NOT NULL UNIQUE, -- Cth: 'TRX-202611-001'
  nama_acara TEXT NOT NULL,
  penanggung_jawab TEXT NOT NULL,
  kamar_rayon TEXT NOT NULL,
  no_wa TEXT NOT NULL,
  waktu_pinjam TIMESTAMPTZ DEFAULT NOW(),
  estimasi_kembali TIMESTAMPTZ NOT NULL,
  waktu_kembali_aktual TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'aktif' CHECK (status IN ('aktif', 'selesai', 'terlambat', 'dibatalkan')),
  petugas_checkout TEXT NOT NULL,
  petugas_checkin TEXT,
  catatan TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 6. TABEL DETAIL BARANG PINJAM & INSPEKSI KEMBALI (CHECK-IN)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS snd_peminjaman_item (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  peminjaman_id UUID REFERENCES snd_peminjaman(id) ON DELETE CASCADE,
  aset_id UUID REFERENCES snd_aset(id) ON DELETE RESTRICT,
  
  -- Status Check-In
  status_kembali BOOLEAN DEFAULT false,
  waktu_scan_kembali TIMESTAMPTZ,
  kondisi_kembali TEXT DEFAULT 'baik' CHECK (kondisi_kembali IN ('baik', 'rusak_ringan', 'rusak_berat')),
  catatan_kerusakan TEXT,
  foto_bukti_kerusakan TEXT,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 7. TABEL LOG SERVIS BENGKEL & PEMELIHARAAN (MAINTENANCE LOG)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS snd_riwayat_servis (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  aset_id UUID REFERENCES snd_aset(id) ON DELETE CASCADE,
  tanggal_masuk DATE DEFAULT CURRENT_DATE,
  keluhan_kerusakan TEXT NOT NULL,
  komponen_diganti TEXT,
  bengkel_teknisi TEXT,
  biaya NUMERIC DEFAULT 0,
  status TEXT DEFAULT 'sedang_servis' CHECK (status IN ('sedang_servis', 'selesai', 'tidak_bisa_diperbaiki')),
  tanggal_selesai DATE,
  catatan_pimpinan TEXT,
  dicatat_oleh TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- -----------------------------------------------------------------------------
-- 8. TRIGGER OTOMATIS: UPDATE STATUS ASET SAAT CHECKOUT & CHECKIN
-- -----------------------------------------------------------------------------

-- Trigger saat barang dipinjam (ubah status aset -> 'dipinjam')
CREATE OR REPLACE FUNCTION trg_aset_dipinjam()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE snd_aset
  SET status = 'dipinjam',
      peminjam_terakhir = (SELECT penanggung_jawab || ' (' || nama_acara || ')' FROM snd_peminjaman WHERE id = NEW.peminjaman_id),
      updated_at = NOW()
  WHERE id = NEW.aset_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_aset_dipinjam
AFTER INSERT ON snd_peminjaman_item
FOR EACH ROW
EXECUTE FUNCTION trg_aset_dipinjam();

-- Trigger saat barang dikembalikan (ubah status aset -> 'tersedia' atau 'servis')
CREATE OR REPLACE FUNCTION trg_aset_dikembalikan()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status_kembali = true AND OLD.status_kembali = false THEN
    IF NEW.kondisi_kembali IN ('rusak_ringan', 'rusak_berat') THEN
      UPDATE snd_aset
      SET status = 'servis',
          kondisi = NEW.kondisi_kembali,
          updated_at = NOW()
      WHERE id = NEW.aset_id;
    ELSE
      UPDATE snd_aset
      SET status = 'tersedia',
          kondisi = 'baik',
          updated_at = NOW()
      WHERE id = NEW.aset_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_aset_dikembalikan
AFTER UPDATE OF status_kembali ON snd_peminjaman_item
FOR EACH ROW
EXECUTE FUNCTION trg_aset_dikembalikan();

-- -----------------------------------------------------------------------------
-- 9. DATA AWAL (SEED DATA SAMPLE)
-- -----------------------------------------------------------------------------
INSERT INTO snd_kategori (nama, kode_prefix, deskripsi, urutan) VALUES
  ('Active & Passive Speaker', 'SPK', 'Speaker aktif panggung, monitor, pasif', 1),
  ('Mikrofon Wireless & Kabel', 'MIC', 'Microphone genggam, clip-on, headset', 2),
  ('Mixer & Equalizer Audio', 'MIX', 'Konsol mixer analog dan digital', 3),
  ('Kabel XLR, Jack & Roll', 'KBL', 'Kabel mikrofon, kabel speaker, snake cable', 4),
  ('Stand Mic, Speaker & Genset', 'STD', 'Stand tripod speaker, stand boom, catu daya', 5)
ON CONFLICT (kode_prefix) DO NOTHING;

INSERT INTO snd_lokasi (nama_zona, kode_rak, keterangan) VALUES
  ('Zona Speaker Utama', 'RAK-A01', 'Rak bawah sisi timur gudang'),
  ('Zona Speaker Pasif', 'RAK-A02', 'Rak susun 2 sisi timur'),
  ('Lemari Koper Mikrofon', 'RAK-B01', 'Lemari kaca kunci gembok'),
  ('Meja Operator & Mixer', 'RAK-B04', 'Meja uji fungsi tengah'),
  ('Gantungan Kabel & Jack', 'RAK-C01', 'Dinding sisi utara'),
  ('Sudut Stand & Genset', 'ZONA-D', 'Lantai bebas sisi barat')
ON CONFLICT DO NOTHING;

-- Selesai
