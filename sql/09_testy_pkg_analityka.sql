/* =====================================================================
   TESTY PKG_ANALITYKA
   Uruchom klawiszem F5 na świeżych danych (01 -> 02 -> 04 -> 06 -> 08).
   Pakiet tylko czyta dane – nic nie zmienia.
   Wartości oczekiwane policzone dla stanu na 2026-10-27; pozycje zależne
   od "dzisiaj" (trwające wypożyczenia, alerty) mogą się później zmieniać.
   ===================================================================== */
SET SERVEROUTPUT ON SIZE UNLIMITED
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';


/* ---------------------------------------------------------------------
   TEST 1 – F1 f_ranking_modeli, rok 2026
   Oczekiwane: 7 modeli po 1 wypożyczeniu (udział 14.3%), kolejność wg przychodu:
     1 Tesla Model 3 1674.40 | 2 Toyota RAV4 996 | 3 Renault Master 777 |
     4 Toyota Corolla 636 | 5 Volkswagen Golf 596 | 6 Kia Sportage 0 / 6 Skoda Octavia 0 (trwają)
   --------------------------------------------------------------------- */
SELECT pozycja, marka_model, kategoria, liczba_wypozyczen, dni_wynajmu, przychod, udzial_proc
  FROM TABLE(pkg_analityka.f_ranking_modeli(DATE '2026-01-01', DATE '2026-12-31'));


/* ---------------------------------------------------------------------
   TEST 2 – F2 f_top_klienci (cała historia)
   Oczekiwane:
     1 Michał Kamiński      2 wyp. 2832.00 (śr. 1416.00) SREBRNY
     2 Agnieszka Lewandowska 1 wyp. 1674.40              SREBRNY
     3 Krzysztof Zieliński  1 wyp.  777.00              STANDARD
     4 Magdalena Szymańska  1 wyp.  596.00              STANDARD
   --------------------------------------------------------------------- */
SELECT pozycja, klient, liczba_wypozyczen, wydano, srednia_wartosc, poziom
  FROM TABLE(pkg_analityka.f_top_klienci(5));


/* ---------------------------------------------------------------------
   TEST 3 – F3 f_przychod_miesieczny, czerwiec–październik 2026
   Oczekiwane:
     2026-06  0 wyp.     0.00  zmiana  -       narastająco    0.00
     2026-07  2 wyp.  2310.40  zmiana  -       narastająco 2310.40
     2026-08  2 wyp.  1373.00  zmiana -40.6%   narastająco 3683.40
     2026-09  1 wyp.  2196.00  zmiana +59.9%   narastająco 5879.40
     2026-10  2 wyp.     0.00  zmiana -100.0%  narastająco 5879.40
   --------------------------------------------------------------------- */
SELECT etykieta, liczba_wypozyczen, przychod, przychod_poprz, zmiana_proc, narastajaco
  FROM TABLE(pkg_analityka.f_przychod_miesieczny(DATE '2026-06-01', DATE '2026-10-31'));

-- Tylko oddział 2 (Kraków). Oczekiwane: 07 = 1674.40, 08 = 596.00, 09 = 2196.00
SELECT etykieta, liczba_wypozyczen, przychod, narastajaco
  FROM TABLE(pkg_analityka.f_przychod_miesieczny(DATE '2026-07-01', DATE '2026-09-30', 2));


/* ---------------------------------------------------------------------
   TEST 4 – F4 f_statystyki_dashboard (obiekt + metoda)
   Oczekiwane: aut 10 (dostępne 7, wypożyczone 2, serwis 1), aktywne 2, przyszłe 2,
               klientów 8, przychód w roku 5879.40, śr. czas 4.6 dnia,
               śr. wartość 935.88, szkody w 40.0% wypożyczeń, wykorzystanie floty 20.0%
   --------------------------------------------------------------------- */
SELECT s.st.liczba_aut            AS aut,
       s.st.aut_dostepnych        AS dostepne,
       s.st.aut_wypozyczonych     AS wypozyczone,
       s.st.aut_w_serwisie        AS w_serwisie,
       s.st.aktywne_wypozyczenia  AS aktywne,
       s.st.przyszle_rezerwacje   AS rezerwacje,
       s.st.liczba_klientow       AS klienci,
       s.st.przychod_30_dni       AS przychod_30d,
       s.st.przychod_rok          AS przychod_rok,
       s.st.sredni_czas_wynajmu   AS sr_czas,
       s.st.srednia_wartosc       AS sr_wartosc,
       s.st.wskaznik_szkod_proc   AS szkody_proc,
       s.st.wykorzystanie_floty_proc() AS wykorzystanie_proc
  FROM (SELECT pkg_analityka.f_statystyki_dashboard() AS st FROM dual) s;


/* ---------------------------------------------------------------------
   TEST 5 – F5 f_rozklad (dynamiczny SQL, zmienna kursorowa)
   Oczekiwane:
     KATEGORIA:        CAR 7, TRUCK 2
     METODA_PLATNOSCI: CARD 5283.40, CASH 596.00
     ODDZIAL:          Kraków Lotnisko 4466.40, Warszawa Mokotów 777.00, Rzeszów Centrum 636.00
     DZIEN_TYGODNIA:   9 rezerwacji rozłożonych na dni tygodnia (pon -> nd)
     zły wymiar:       błąd -20030
   --------------------------------------------------------------------- */
SELECT 'KATEGORIA' AS wymiar, etykieta, wartosc FROM TABLE(pkg_analityka.f_rozklad('KATEGORIA'))
UNION ALL
SELECT 'METODA_PLATNOSCI', etykieta, wartosc FROM TABLE(pkg_analityka.f_rozklad('METODA_PLATNOSCI'))
UNION ALL
SELECT 'ODDZIAL', etykieta, wartosc FROM TABLE(pkg_analityka.f_rozklad('ODDZIAL'))
UNION ALL
SELECT 'DZIEN_TYGODNIA', etykieta, wartosc FROM TABLE(pkg_analityka.f_rozklad('dzien_tygodnia'));

DECLARE
  l_t  t_punkt_tab;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 5: nieznany wymiar ===');
  l_t := pkg_analityka.f_rozklad('KOLOR');
  DBMS_OUTPUT.PUT_LINE('BŁĄD TESTU');
EXCEPTION
  WHEN pkg_analityka.e_zly_parametr THEN
    DBMS_OUTPUT.PUT_LINE('OK, oczekiwany błąd: ' || SQLERRM);
END;
/


/* ---------------------------------------------------------------------
   TEST 6 – P1 raport miesięczny za sierpień 2026
   Oczekiwane: przychód 1373.00 zł (poprzedni 2310.40, zmiana -40.6%),
               2 wypożyczenia, 1 nowa rezerwacja, 1 szkoda (300.00 zł);
               top modele: Renault Master, Volkswagen Golf;
               top klienci: Krzysztof Zieliński 777.00, Magdalena Szymańska 596.00
   --------------------------------------------------------------------- */
BEGIN
  pkg_analityka.p_raport_miesieczny(2026, 8);
END;
/


/* ---------------------------------------------------------------------
   TEST 7 – P2 porównanie oddziałów 2026-07-01 – 2026-10-31
   Oczekiwane: 1. Kraków Lotnisko 4116.40 (73.8%), 2. Rzeszów Centrum 736.00 (13.2%),
               3. Warszawa Mokotów 727.00 (13.0%)
   --------------------------------------------------------------------- */
BEGIN
  DBMS_OUTPUT.PUT_LINE('');
  pkg_analityka.p_porownaj_oddzialy(DATE '2026-07-01', DATE '2026-10-31');
END;
/


/* ---------------------------------------------------------------------
   TEST 8 – P3 raport JSON
   Oczekiwane: poprawny JSON (IS JSON = TAK) z tablicami top_modele, top_klienci,
               przychod_miesieczny, przychod_wg_oddzialow
   --------------------------------------------------------------------- */
DECLARE
  l_json   CLOB;
  l_ok     NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('');
  DBMS_OUTPUT.PUT_LINE('=== TEST 8: raport JSON ===');
  pkg_analityka.p_raport_json(DATE '2026-07-01', DATE '2026-09-30', l_json);

  SELECT COUNT(*) INTO l_ok FROM dual WHERE l_json IS JSON;
  DBMS_OUTPUT.PUT_LINE('Poprawny JSON: ' || CASE WHEN l_ok = 1 THEN 'TAK' ELSE 'NIE' END
                       || ', długość ' || DBMS_LOB.GETLENGTH(l_json) || ' znaków');
  DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(l_json, 3000, 1));
END;
/


/* ---------------------------------------------------------------------
   TEST 9 – P4 wykrywanie anomalii (stan na 2026-10-27)
   Oczekiwane: 1) brak  2) brak  3) Michał Kamiński: 1 szkoda, 1200.00 zł
               4) WA 3REN7 Renault Master: przychód 777.00, serwis 850.00
               5) 7 aut bez wynajmu od 60+ dni (RZ 9012C, WA 5COR2, RZ 3RAV4 – nigdy;
                  RZ 1234A, KR 4T3SL, WA 3REN7, KR 1GOLF)
               Łącznie alertów: 9
   --------------------------------------------------------------------- */
DECLARE
  l_ile  PLS_INTEGER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('');
  pkg_analityka.p_wykryj_anomalie(60, l_ile);
END;
/
