/* =====================================================================
   TESTY PKG_FLOTA
   Uruchom w SQL Developerze klawiszem F5 (Run Script) na świeżych danych
   z 01_schemat_i_dane.sql. Na końcu jest ROLLBACK – dane wracają do stanu
   wyjściowego (zostają tylko wpisy w ERROR_LOG).
   Przy każdym teście w komentarzu jest OCZEKIWANY wynik.
   ===================================================================== */
SET SERVEROUTPUT ON SIZE UNLIMITED
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';


/* ---------------------------------------------------------------------
   TEST 1 – F1 f_km_do_przegladu (interwał przeglądu: 15000 km)
   Oczekiwane: auto 8 = 15000 (przegląd przy 102400 km),
               auto 4 = 2500 (12500 km, bez przeglądu),
               auto 1 = -30200 (45200 km, nigdy nie przeglądane)
   --------------------------------------------------------------------- */
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 1: km do przeglądu ===');
  DBMS_OUTPUT.PUT_LINE('Auto 8: ' || pkg_flota.f_km_do_przegladu(8));
  DBMS_OUTPUT.PUT_LINE('Auto 4: ' || pkg_flota.f_km_do_przegladu(4));
  DBMS_OUTPUT.PUT_LINE('Auto 1: ' || pkg_flota.f_km_do_przegladu(1));
END;
/


/* ---------------------------------------------------------------------
   TEST 2 – F2 f_auta_do_przegladu (kolekcja w SELECT)
   Oczekiwane (próg 3000 km): 8 aut, od RZ 9012C (-73000) do KR 4T3SL (2500, WKROTCE);
                              nie ma WA 8KIA1 (5200) ani WA 3REN7 (15000)
   --------------------------------------------------------------------- */
SELECT nr_rejestracyjny, pojazd, oddzial, przebieg, przebieg_ost_przegladu,
       km_do_przegladu, pilnosc
  FROM TABLE(pkg_flota.f_auta_do_przegladu(3000));

-- Oddział 3 (Warszawa). Oczekiwane: tylko WA 5COR2
SELECT nr_rejestracyjny, pojazd, km_do_przegladu, pilnosc
  FROM TABLE(pkg_flota.f_auta_do_przegladu(3000, 3));


/* ---------------------------------------------------------------------
   TEST 3 – F3 f_raport_oddzialu (obiekt + metody saldo() i srednia_na_wypozyczenie())
   Okres 2026-07-01 – 2026-10-31. Oczekiwane:
     Rzeszów Centrum:  2 wyp., najem  636.00, szkody    0.00, kaucje 500.00, serwis  400.00 -> saldo  736.00, śr.  318.00
     Kraków Lotnisko:  3 wyp., najem 3266.40, szkody 1200.00, kaucje   0.00, serwis  350.00 -> saldo 4116.40, śr. 1088.80
     Warszawa Mokotów: 2 wyp., najem  777.00, szkody    0.00, kaucje 800.00, serwis  850.00 -> saldo  727.00, śr.  388.50
   --------------------------------------------------------------------- */
SELECT r.rap.oddzial                      AS oddzial,
       r.rap.liczba_wypozyczen            AS wypozyczen,
       r.rap.przychod_najem               AS najem,
       r.rap.oplaty_szkody                AS szkody,
       r.rap.kaucje_pobrane               AS kaucje,
       r.rap.zwroty                       AS zwroty,
       r.rap.koszt_serwisu                AS serwis,
       r.rap.saldo()                      AS saldo,
       r.rap.srednia_na_wypozyczenie()    AS srednia
  FROM (SELECT pkg_flota.f_raport_oddzialu(b.branch_id, DATE '2026-07-01', DATE '2026-10-31') AS rap
          FROM branches b
         ORDER BY b.branch_id) r;


/* ---------------------------------------------------------------------
   TEST 4 – F4 f_oblozenie_floty, okres 2026-07-01 – 2026-09-30 (92 dni)
   Oczekiwane (pierwsze wiersze):
     KR 4T3SL 7 dni  7.6%  1674.40
     KR 1GOLF 5 dni  5.4%   596.00
     KR 77RAV 4 dni  4.3%  2196.00  (najem 996 + szkoda 1200)
     RZ 1234A 4 dni  4.3%   636.00
     WA 3REN7 3 dni  3.3%   777.00
     pozostałe 0 dni
   --------------------------------------------------------------------- */
SELECT nr_rejestracyjny, pojazd, oddzial, dni_wynajmu, dni_okresu, oblozenie_proc, przychod
  FROM TABLE(pkg_flota.f_oblozenie_floty(DATE '2026-07-01', DATE '2026-09-30'));


/* ---------------------------------------------------------------------
   TEST 5 – F5 f_koszt_serwisu
   Oczekiwane: auto 8 = 850, auto 1 = 400, auto 5 = 0 (serwis w toku, bez kosztu)
   --------------------------------------------------------------------- */
SELECT pkg_flota.f_koszt_serwisu(8) AS auto_8,
       pkg_flota.f_koszt_serwisu(1) AS auto_1,
       pkg_flota.f_koszt_serwisu(5) AS auto_5
  FROM dual;


/* ---------------------------------------------------------------------
   TEST 6 – P6 raport zbiorczy (przed testami zmieniającymi dane)
   Oczekiwane: 3 oddziały z wartościami jak w teście 3, saldo łączne 5579.40 zł,
               lista aut do przeglądu (<= 1000 km): 7 aut przeterminowanych
   --------------------------------------------------------------------- */
BEGIN
  pkg_flota.p_drukuj_raport_floty(DATE '2026-07-01', DATE '2026-10-31');
END;
/


/* ---------------------------------------------------------------------
   TEST 7 – P2 p_zakoncz_serwis
   Serwis 4 (auto 5, naprawa zderzaka w toku).
   Oczekiwane: auto 5 -> AVAILABLE, koszt 1150; ponowne zakończenie = -20011
   --------------------------------------------------------------------- */
DECLARE
  l_txt  VARCHAR2(200);
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 7: zakończenie serwisu ===');
  pkg_flota.p_zakoncz_serwis(4, 1150, 'Wymieniono zderzak');

  SELECT v.vehicle_status || ', koszt serwisu: ' || m.cost || ', koniec: ' || TO_CHAR(m.end_date, 'YYYY-MM-DD')
    INTO l_txt
    FROM maintenance m JOIN vehicles v ON v.vehicle_id = m.vehicle_id
   WHERE m.maintenance_id = 4;
  DBMS_OUTPUT.PUT_LINE('Auto 5: ' || l_txt);

  BEGIN
    pkg_flota.p_zakoncz_serwis(4, 100);
    DBMS_OUTPUT.PUT_LINE('BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_serwis THEN
      DBMS_OUTPUT.PUT_LINE('OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 8 – P1 p_skieruj_do_serwisu (+ P2 z błędnym kosztem)
   Oczekiwane: auto 4 -> MAINTENANCE; ponownie = -20011; auto 2 (RENTED) = -20010;
               nieistniejący typ serwisu = -20006; zakończenie z kosztem -5 = -20012
   --------------------------------------------------------------------- */
DECLARE
  l_id     maintenance.maintenance_id%TYPE;
  l_id2    maintenance.maintenance_id%TYPE;
  l_stat   vehicles.vehicle_status%TYPE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 8: skierowanie do serwisu ===');
  pkg_flota.p_skieruj_do_serwisu(4, 1, 3, 'Przegląd przed sezonem zimowym', l_id);
  SELECT vehicle_status INTO l_stat FROM vehicles WHERE vehicle_id = 4;
  DBMS_OUTPUT.PUT_LINE('Utworzono serwis nr ' || l_id || ', auto 4: ' || l_stat);

  BEGIN
    pkg_flota.p_skieruj_do_serwisu(4, 2, 3, NULL, l_id2);
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_serwis THEN
      DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_skieruj_do_serwisu(2, 1, 2, NULL, l_id2);
    DBMS_OUTPUT.PUT_LINE('b) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_zly_status_auta THEN
      DBMS_OUTPUT.PUT_LINE('b) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_skieruj_do_serwisu(10, 99, 2, NULL, l_id2);
    DBMS_OUTPUT.PUT_LINE('c) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_nie_znaleziono THEN
      DBMS_OUTPUT.PUT_LINE('c) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_zakoncz_serwis(l_id, -5);
    DBMS_OUTPUT.PUT_LINE('d) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_zle_dane THEN
      DBMS_OUTPUT.PUT_LINE('d) OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 9 – P3 p_przenies_auto
   Oczekiwane: auto 6 (Kraków) -> Rzeszów Centrum; ponownie do Rzeszowa = -20012;
               auto 3 (rezerwacja 8) = -20013; auto 7 (RENTED) = -20010
   --------------------------------------------------------------------- */
DECLARE
  l_txt  VARCHAR2(200);
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 9: przeniesienie auta ===');
  pkg_flota.p_przenies_auto(6, 1);
  SELECT v.license_plate || ' -> ' || b.branch_name INTO l_txt
    FROM vehicles v JOIN branches b ON b.branch_id = v.branch_id WHERE v.vehicle_id = 6;
  DBMS_OUTPUT.PUT_LINE('Przeniesiono: ' || l_txt);

  BEGIN
    pkg_flota.p_przenies_auto(6, 1);
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_zle_dane THEN
      DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_przenies_auto(3, 2);
    DBMS_OUTPUT.PUT_LINE('b) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_auto_zarezerwowane THEN
      DBMS_OUTPUT.PUT_LINE('b) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_przenies_auto(7, 1);
    DBMS_OUTPUT.PUT_LINE('c) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_zly_status_auta THEN
      DBMS_OUTPUT.PUT_LINE('c) OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 10 – P4 p_dodaj_pojazd + P5 p_wycofaj_pojazd
   Oczekiwane: nowe auto RZ 777TE (ID >= 100) -> po wycofaniu RETIRED;
               duplikat numeru = -20012 (DUP_VAL_ON_INDEX zamieniony na komunikat);
               zły VIN = -20012; wycofanie auta 9 (rezerwacja 9) = -20013;
               auta 7 (RENTED) = -20010; auta 4 (otwarty serwis z testu 8) = -20011
   --------------------------------------------------------------------- */
DECLARE
  l_id    vehicles.vehicle_id%TYPE;
  l_id2   vehicles.vehicle_id%TYPE;
  l_stat  vehicles.vehicle_status%TYPE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 10: dodanie i wycofanie pojazdu ===');
  pkg_flota.p_dodaj_pojazd(1, 3, 'rz 777te', 'WVWZZZCDZMW000777', 'Czarny', 0, l_id);
  DBMS_OUTPUT.PUT_LINE('Dodano pojazd ID ' || l_id);

  BEGIN
    pkg_flota.p_dodaj_pojazd(2, 1, 'RZ 777TE', 'JTDBR3FE20A000777', 'Biały', 0, l_id2);
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_zle_dane THEN
      DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_dodaj_pojazd(2, 1, 'KR 12345', 'ABC123', 'Biały', 0, l_id2);
    DBMS_OUTPUT.PUT_LINE('b) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_zle_dane THEN
      DBMS_OUTPUT.PUT_LINE('b) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  pkg_flota.p_wycofaj_pojazd(l_id);
  SELECT vehicle_status INTO l_stat FROM vehicles WHERE vehicle_id = l_id;
  DBMS_OUTPUT.PUT_LINE('Pojazd ' || l_id || ' po wycofaniu: ' || l_stat);

  BEGIN
    pkg_flota.p_wycofaj_pojazd(9);
    DBMS_OUTPUT.PUT_LINE('c) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_auto_zarezerwowane THEN
      DBMS_OUTPUT.PUT_LINE('c) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_wycofaj_pojazd(7);
    DBMS_OUTPUT.PUT_LINE('d) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_zly_status_auta THEN
      DBMS_OUTPUT.PUT_LINE('d) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_flota.p_wycofaj_pojazd(4);
    DBMS_OUTPUT.PUT_LINE('e) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_flota.e_serwis THEN
      DBMS_OUTPUT.PUT_LINE('e) OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 11 – dziennik błędów (ostatnie wpisy z PKG_FLOTA)
   --------------------------------------------------------------------- */
SELECT log_id, TO_CHAR(log_date, 'HH24:MI:SS') AS czas, source_name, error_code, error_message
  FROM error_log
 WHERE source_name LIKE 'PKG_FLOTA%'
 ORDER BY log_id DESC
 FETCH FIRST 15 ROWS ONLY;


-- Przywrócenie danych przykładowych
ROLLBACK;
