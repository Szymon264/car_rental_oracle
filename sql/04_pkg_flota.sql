/* =====================================================================
   PAKIET 2: PKG_FLOTA – serwis, zarządzanie flotą i raporty
   Wymaga: 01_schemat_i_dane.sql oraz 02_pkg_wypozyczenia.sql
           (korzysta z tabeli ERROR_LOG i procedury P_LOGUJ_BLAD)

   Zawartość skryptu:
     1. Usunięcie starego pakietu i typów (skrypt można uruchamiać ponownie)
     2. Typy obiektowe i kolekcje SQL (raporty)
     3. Specyfikacja pakietu
     4. Ciało pakietu

   Funkcje (5):
     F1 f_km_do_przegladu     – ile km zostało do przeglądu okresowego
     F2 f_auta_do_przegladu   – UC12: lista aut do przeglądu -> kolekcja T_PRZEGLAD_TAB
     F3 f_raport_oddzialu     – UC13: wynik finansowy oddziału -> obiekt T_RAPORT_ODDZIALU
     F4 f_oblozenie_floty     – UC14: obłożenie aut w okresie -> kolekcja T_OBLOZENIE_TAB
     F5 f_koszt_serwisu       – suma kosztów serwisu pojazdu
   Procedury (6):
     P1 p_skieruj_do_serwisu  – UC09
     P2 p_zakoncz_serwis      – UC10
     P3 p_przenies_auto       – UC11
     P4 p_dodaj_pojazd        – UC15 (DUP_VAL_ON_INDEX -> własny komunikat)
     P5 p_wycofaj_pojazd      – UC15
     P6 p_drukuj_raport_floty – zbiorczy raport (zagnieżdżone pętle kursorowe)

   Kody błędów (wspólna numeracja z PKG_WYPOZYCZENIA):
     -20002 nieprawidłowe daty           -20011 serwis już otwarty / już zamknięty
     -20006 nie znaleziono rekordu       -20012 nieprawidłowe dane
     -20010 zły status pojazdu           -20013 pojazd ma przyszłe rezerwacje
   ===================================================================== */


/* =====================================================================
   1. USUNIĘCIE STAREGO PAKIETU I TYPÓW
   ===================================================================== */
BEGIN
  FOR p IN (SELECT object_name FROM user_objects
             WHERE object_type = 'PACKAGE' AND object_name = 'PKG_FLOTA')
  LOOP
    EXECUTE IMMEDIATE 'DROP PACKAGE pkg_flota';
  END LOOP;

  FOR t IN (SELECT type_name FROM user_types
             WHERE type_name IN ('T_PRZEGLAD_TAB','T_OBLOZENIE_TAB',
                                 'T_PRZEGLAD','T_OBLOZENIE','T_RAPORT_ODDZIALU')
             ORDER BY CASE WHEN type_name LIKE '%TAB' THEN 0 ELSE 1 END)
  LOOP
    EXECUTE IMMEDIATE 'DROP TYPE ' || t.type_name || ' FORCE';
  END LOOP;
END;
/


/* =====================================================================
   2. TYPY OBIEKTOWE I KOLEKCJE
   ===================================================================== */

-- Pozycja listy aut do przeglądu (UC12)
CREATE OR REPLACE TYPE t_przeglad AS OBJECT (
  vehicle_id              NUMBER,
  nr_rejestracyjny        VARCHAR2(10 CHAR),
  pojazd                  VARCHAR2(110 CHAR),
  oddzial                 VARCHAR2(60 CHAR),
  przebieg                NUMBER,
  przebieg_ost_przegladu  NUMBER,
  data_ost_przegladu      DATE,
  interwal_km             NUMBER,
  km_do_przegladu         NUMBER,
  pilnosc                 VARCHAR2(20 CHAR)     -- PRZETERMINOWANY / WKROTCE
);
/
CREATE OR REPLACE TYPE t_przeglad_tab AS TABLE OF t_przeglad;
/

-- Obłożenie pojedynczego auta w okresie (UC14)
CREATE OR REPLACE TYPE t_oblozenie AS OBJECT (
  vehicle_id        NUMBER,
  nr_rejestracyjny  VARCHAR2(10 CHAR),
  pojazd            VARCHAR2(110 CHAR),
  oddzial           VARCHAR2(60 CHAR),
  dni_wynajmu       NUMBER,
  dni_okresu        NUMBER,
  oblozenie_proc    NUMBER(5,1),
  przychod          NUMBER(12,2)
);
/
CREATE OR REPLACE TYPE t_oblozenie_tab AS TABLE OF t_oblozenie;
/

-- Wynik finansowy oddziału (UC13) – obiekt z metodami
CREATE OR REPLACE TYPE t_raport_oddzialu AS OBJECT (
  branch_id          NUMBER,
  oddzial            VARCHAR2(60 CHAR),
  okres_od           DATE,
  okres_do           DATE,
  liczba_wypozyczen  NUMBER,
  przychod_najem     NUMBER(12,2),
  oplaty_szkody      NUMBER(12,2),
  kaucje_pobrane     NUMBER(12,2),
  zwroty             NUMBER(12,2),
  koszt_serwisu      NUMBER(12,2),
  MEMBER FUNCTION saldo RETURN NUMBER,
  MEMBER FUNCTION srednia_na_wypozyczenie RETURN NUMBER
);
/
SHOW ERRORS

CREATE OR REPLACE TYPE BODY t_raport_oddzialu AS
  -- saldo = wpływy (najem + opłaty + kaucje) - zwroty - koszty serwisu
  MEMBER FUNCTION saldo RETURN NUMBER IS
  BEGIN
    RETURN przychod_najem + oplaty_szkody + kaucje_pobrane - zwroty - koszt_serwisu;
  END saldo;

  MEMBER FUNCTION srednia_na_wypozyczenie RETURN NUMBER IS
  BEGIN
    IF liczba_wypozyczen > 0 THEN
      RETURN ROUND(przychod_najem / liczba_wypozyczen, 2);
    END IF;
    RETURN 0;
  END srednia_na_wypozyczenie;
END;
/
SHOW ERRORS


/* =====================================================================
   3. SPECYFIKACJA PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE pkg_flota AS

  c_typ_przegladu  CONSTANT VARCHAR2(60) := 'Przegląd okresowy';

  e_zle_daty            EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zle_daty,           -20002);
  e_nie_znaleziono      EXCEPTION;  PRAGMA EXCEPTION_INIT(e_nie_znaleziono,     -20006);
  e_zly_status_auta     EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zly_status_auta,    -20010);
  e_serwis              EXCEPTION;  PRAGMA EXCEPTION_INIT(e_serwis,             -20011);
  e_zle_dane            EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zle_dane,           -20012);
  e_auto_zarezerwowane  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_auto_zarezerwowane, -20013);

  /* ---------------- FUNKCJE ---------------- */

  -- F1: km do kolejnego przeglądu okresowego (ujemne = przeglądu nie zrobiono w terminie)
  FUNCTION f_km_do_przegladu (
    p_vehicle_id  IN vehicles.vehicle_id%TYPE
  ) RETURN NUMBER;

  -- F2 (UC12): auta, którym zostało <= p_prog_km do przeglądu
  FUNCTION f_auta_do_przegladu (
    p_prog_km    IN NUMBER DEFAULT 1000,
    p_branch_id  IN branches.branch_id%TYPE DEFAULT NULL
  ) RETURN t_przeglad_tab;

  -- F3 (UC13): wynik finansowy oddziału w okresie [p_od, p_do] (obie daty włącznie)
  FUNCTION f_raport_oddzialu (
    p_branch_id  IN branches.branch_id%TYPE,
    p_od         IN DATE,
    p_do         IN DATE
  ) RETURN t_raport_oddzialu;

  -- F4 (UC14): obłożenie aut w okresie [p_od, p_do] (obie daty włącznie)
  FUNCTION f_oblozenie_floty (
    p_od         IN DATE,
    p_do         IN DATE,
    p_branch_id  IN branches.branch_id%TYPE DEFAULT NULL
  ) RETURN t_oblozenie_tab;

  -- F5: suma kosztów serwisu pojazdu (opcjonalnie w okresie)
  FUNCTION f_koszt_serwisu (
    p_vehicle_id  IN vehicles.vehicle_id%TYPE,
    p_od          IN DATE DEFAULT NULL,
    p_do          IN DATE DEFAULT NULL
  ) RETURN NUMBER;

  /* ---------------- PROCEDURY ---------------- */

  -- P1 (UC09)
  PROCEDURE p_skieruj_do_serwisu (
    p_vehicle_id      IN  vehicles.vehicle_id%TYPE,
    p_typ_id          IN  maintenance_types.maintenance_type_id%TYPE,
    p_employee_id     IN  employees.user_id%TYPE,
    p_opis            IN  maintenance.description%TYPE DEFAULT NULL,
    o_maintenance_id  OUT maintenance.maintenance_id%TYPE
  );

  -- P2 (UC10)
  PROCEDURE p_zakoncz_serwis (
    p_maintenance_id  IN maintenance.maintenance_id%TYPE,
    p_koszt           IN maintenance.cost%TYPE,
    p_uwagi           IN VARCHAR2 DEFAULT NULL
  );

  -- P3 (UC11)
  PROCEDURE p_przenies_auto (
    p_vehicle_id         IN vehicles.vehicle_id%TYPE,
    p_branch_docelowy    IN branches.branch_id%TYPE
  );

  -- P4 (UC15)
  PROCEDURE p_dodaj_pojazd (
    p_branch_id        IN  branches.branch_id%TYPE,
    p_vehicle_type_id  IN  vehicle_types.vehicle_type_id%TYPE,
    p_nr_rej           IN  vehicles.license_plate%TYPE,
    p_vin              IN  VARCHAR2,
    p_kolor            IN  vehicles.color%TYPE DEFAULT NULL,
    p_przebieg         IN  vehicles.mileage%TYPE DEFAULT 0,
    o_vehicle_id       OUT vehicles.vehicle_id%TYPE
  );

  -- P5 (UC15)
  PROCEDURE p_wycofaj_pojazd (
    p_vehicle_id  IN vehicles.vehicle_id%TYPE
  );

  -- P6: raport zbiorczy floty (DBMS_OUTPUT)
  PROCEDURE p_drukuj_raport_floty (
    p_od  IN DATE,
    p_do  IN DATE
  );

END pkg_flota;
/
SHOW ERRORS


/* =====================================================================
   4. CIAŁO PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE BODY pkg_flota AS

  /* =================== ELEMENTY PRYWATNE =================== */

  PROCEDURE sprawdz_okres (p_od IN DATE, p_do IN DATE) IS
  BEGIN
    IF p_od IS NULL OR p_do IS NULL OR TRUNC(p_do) < TRUNC(p_od) THEN
      RAISE_APPLICATION_ERROR(-20002,
        'Nieprawidłowy okres: data końcowa nie może być wcześniejsza niż początkowa.');
    END IF;
  END sprawdz_okres;

  -- ID i interwał przeglądu okresowego ze słownika
  PROCEDURE typ_przegladu (
    o_typ_id    OUT maintenance_types.maintenance_type_id%TYPE,
    o_interwal  OUT maintenance_types.interval_km%TYPE
  ) IS
  BEGIN
    SELECT maintenance_type_id, interval_km
      INTO o_typ_id, o_interwal
      FROM maintenance_types
     WHERE type_name = c_typ_przegladu;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20006,
        'Brak typu serwisu "' || c_typ_przegladu || '" w słowniku MAINTENANCE_TYPES.');
  END typ_przegladu;

  -- Pobranie pojazdu z blokadą wiersza
  FUNCTION pobierz_pojazd (p_vehicle_id IN vehicles.vehicle_id%TYPE)
    RETURN vehicles%ROWTYPE
  IS
    l_v  vehicles%ROWTYPE;
  BEGIN
    SELECT * INTO l_v FROM vehicles WHERE vehicle_id = p_vehicle_id FOR UPDATE;
    RETURN l_v;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pojazdu o ID ' || p_vehicle_id || '.');
  END pobierz_pojazd;

  -- Liczba przyszłych (niezrealizowanych) rezerwacji pojazdu
  FUNCTION przyszle_rezerwacje (p_vehicle_id IN vehicles.vehicle_id%TYPE) RETURN NUMBER IS
    l_ile  NUMBER;
  BEGIN
    SELECT COUNT(*)
      INTO l_ile
      FROM bookings
     WHERE vehicle_id = p_vehicle_id
       AND booking_status = 'RESERVED';
    RETURN l_ile;
  END przyszle_rezerwacje;


  /* =================== FUNKCJE PUBLICZNE =================== */

  -- F1
  FUNCTION f_km_do_przegladu (
    p_vehicle_id  IN vehicles.vehicle_id%TYPE
  ) RETURN NUMBER IS
    l_typ_id    maintenance_types.maintenance_type_id%TYPE;
    l_interwal  maintenance_types.interval_km%TYPE;
    l_przebieg  vehicles.mileage%TYPE;
    l_ostatni   NUMBER;
  BEGIN
    typ_przegladu(l_typ_id, l_interwal);

    BEGIN
      SELECT mileage INTO l_przebieg FROM vehicles WHERE vehicle_id = p_vehicle_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pojazdu o ID ' || p_vehicle_id || '.');
    END;

    -- auto bez żadnego przeglądu liczymy od 0 km
    SELECT NVL(MAX(mileage_at_service), 0)
      INTO l_ostatni
      FROM maintenance
     WHERE vehicle_id          = p_vehicle_id
       AND maintenance_type_id = l_typ_id
       AND end_date IS NOT NULL;

    RETURN l_interwal - (l_przebieg - l_ostatni);
  END f_km_do_przegladu;

  -- F2: kursor jawny z parametrami w pętli FOR + budowa kolekcji obiektów
  FUNCTION f_auta_do_przegladu (
    p_prog_km    IN NUMBER DEFAULT 1000,
    p_branch_id  IN branches.branch_id%TYPE DEFAULT NULL
  ) RETURN t_przeglad_tab IS

    l_typ_id    maintenance_types.maintenance_type_id%TYPE;
    l_interwal  maintenance_types.interval_km%TYPE;
    l_km_do     NUMBER;
    l_wynik     t_przeglad_tab := t_przeglad_tab();

    CURSOR c_auta (cp_typ NUMBER, cp_oddzial NUMBER) IS
      SELECT v.vehicle_id, v.license_plate,
             m.make_name || ' ' || vt.model_name AS pojazd,
             b.branch_name, v.mileage,
             NVL(ost.km, 0) AS km_ost, ost.data_ost
        FROM vehicles v
        JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
        JOIN makes m          ON m.make_id          = vt.make_id
        JOIN branches b       ON b.branch_id        = v.branch_id
        LEFT JOIN (SELECT vehicle_id,
                          MAX(mileage_at_service) AS km,
                          MAX(end_date)           AS data_ost
                     FROM maintenance
                    WHERE maintenance_type_id = cp_typ
                      AND end_date IS NOT NULL
                    GROUP BY vehicle_id) ost
               ON ost.vehicle_id = v.vehicle_id
       WHERE v.vehicle_status <> 'RETIRED'
         AND (cp_oddzial IS NULL OR v.branch_id = cp_oddzial)
       ORDER BY v.mileage - NVL(ost.km, 0) DESC;
  BEGIN
    IF p_prog_km IS NULL OR p_prog_km < 0 THEN
      RAISE_APPLICATION_ERROR(-20012, 'Próg km musi być liczbą nieujemną.');
    END IF;

    typ_przegladu(l_typ_id, l_interwal);

    FOR r IN c_auta(l_typ_id, p_branch_id) LOOP
      l_km_do := l_interwal - (r.mileage - r.km_ost);

      IF l_km_do <= p_prog_km THEN
        l_wynik.EXTEND;
        l_wynik(l_wynik.LAST) := t_przeglad(
          r.vehicle_id, r.license_plate, r.pojazd, r.branch_name,
          r.mileage, r.km_ost, r.data_ost, l_interwal, l_km_do,
          CASE WHEN l_km_do <= 0 THEN 'PRZETERMINOWANY' ELSE 'WKROTCE' END);
      END IF;
    END LOOP;

    RETURN l_wynik;
  END f_auta_do_przegladu;

  -- F3: agregaty SQL zebrane w jeden obiekt
  FUNCTION f_raport_oddzialu (
    p_branch_id  IN branches.branch_id%TYPE,
    p_od         IN DATE,
    p_do         IN DATE
  ) RETURN t_raport_oddzialu IS
    l_od       DATE := TRUNC(p_od);
    l_do       DATE := TRUNC(p_do);
    l_oddzial  branches.branch_name%TYPE;
    l_liczba   NUMBER;
    l_najem    NUMBER;
    l_szkody   NUMBER;
    l_kaucje   NUMBER;
    l_zwroty   NUMBER;
    l_serwis   NUMBER;
  BEGIN
    sprawdz_okres(p_od, p_do);

    BEGIN
      SELECT branch_name INTO l_oddzial FROM branches WHERE branch_id = p_branch_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono oddziału o ID ' || p_branch_id || '.');
    END;

    -- wypożyczenia rozpoczęte w okresie (bez anulowanych)
    SELECT COUNT(*)
      INTO l_liczba
      FROM bookings b
      JOIN vehicles v ON v.vehicle_id = b.vehicle_id
     WHERE v.branch_id = p_branch_id
       AND b.booking_status <> 'CANCELLED'
       AND TRUNC(b.start_date) BETWEEN l_od AND l_do;

    -- przepływy pieniężne w okresie
    SELECT NVL(SUM(CASE WHEN t.transaction_type = 'PAYMENT'    THEN t.amount END), 0),
           NVL(SUM(CASE WHEN t.transaction_type = 'DAMAGE_FEE' THEN t.amount END), 0),
           NVL(SUM(CASE WHEN t.transaction_type = 'DEPOSIT'    THEN t.amount END), 0),
           NVL(SUM(CASE WHEN t.transaction_type = 'REFUND'     THEN t.amount END), 0)
      INTO l_najem, l_szkody, l_kaucje, l_zwroty
      FROM transactions t
      JOIN bookings b ON b.booking_id = t.booking_id
      JOIN vehicles v ON v.vehicle_id = b.vehicle_id
     WHERE v.branch_id = p_branch_id
       AND TRUNC(t.transaction_date) BETWEEN l_od AND l_do;

    -- koszty serwisu rozpoczętego w okresie
    SELECT NVL(SUM(m.cost), 0)
      INTO l_serwis
      FROM maintenance m
      JOIN vehicles v ON v.vehicle_id = m.vehicle_id
     WHERE v.branch_id = p_branch_id
       AND TRUNC(m.start_date) BETWEEN l_od AND l_do;

    RETURN t_raport_oddzialu(p_branch_id, l_oddzial, l_od, l_do, l_liczba,
                             l_najem, l_szkody, l_kaucje, l_zwroty, l_serwis);
  END f_raport_oddzialu;

  -- F4: BULK COLLECT prosto do kolekcji obiektów (konstruktor T_OBLOZENIE w SELECT)
  FUNCTION f_oblozenie_floty (
    p_od         IN DATE,
    p_do         IN DATE,
    p_branch_id  IN branches.branch_id%TYPE DEFAULT NULL
  ) RETURN t_oblozenie_tab IS
    l_pocz      DATE := TRUNC(p_od);
    l_koniec    DATE := TRUNC(p_do) + 1;            -- okres [p_od, p_do] = [l_pocz, l_koniec)
    l_dni       NUMBER;
    l_wynik     t_oblozenie_tab;
  BEGIN
    sprawdz_okres(p_od, p_do);
    l_dni := l_koniec - l_pocz;

    SELECT t_oblozenie(
             v.vehicle_id, v.license_plate,
             m.make_name || ' ' || vt.model_name,
             br.branch_name,
             NVL(d.dni, 0),
             l_dni,
             ROUND(NVL(d.dni, 0) * 100 / l_dni, 1),
             NVL(p.przychod, 0))
      BULK COLLECT INTO l_wynik
      FROM vehicles v
      JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
      JOIN makes m          ON m.make_id          = vt.make_id
      JOIN branches br      ON br.branch_id       = v.branch_id
      -- dni wynajmu w okresie: część wspólna [start, koniec) z [l_pocz, l_koniec)
      LEFT JOIN (SELECT b.vehicle_id,
                        SUM(GREATEST(0,
                              LEAST(CASE WHEN b.booking_status = 'COMPLETED'
                                           THEN TRUNC(b.actual_return_date)
                                         ELSE GREATEST(TRUNC(b.planned_end_date), TRUNC(SYSDATE))
                                    END, l_koniec)
                              - GREATEST(TRUNC(b.start_date), l_pocz))) AS dni
                   FROM bookings b
                  WHERE b.booking_status IN ('ACTIVE', 'COMPLETED')
                  GROUP BY b.vehicle_id) d
             ON d.vehicle_id = v.vehicle_id
      -- przychód: opłaty za najem i szkody zaksięgowane w okresie
      LEFT JOIN (SELECT b.vehicle_id, SUM(t.amount) AS przychod
                   FROM transactions t
                   JOIN bookings b ON b.booking_id = t.booking_id
                  WHERE t.transaction_type IN ('PAYMENT', 'DAMAGE_FEE')
                    AND TRUNC(t.transaction_date) >= l_pocz
                    AND TRUNC(t.transaction_date) <  l_koniec
                  GROUP BY b.vehicle_id) p
             ON p.vehicle_id = v.vehicle_id
     WHERE v.vehicle_status <> 'RETIRED'
       AND (p_branch_id IS NULL OR v.branch_id = p_branch_id)
     ORDER BY NVL(d.dni, 0) DESC, v.license_plate;

    RETURN l_wynik;
  END f_oblozenie_floty;

  -- F5
  FUNCTION f_koszt_serwisu (
    p_vehicle_id  IN vehicles.vehicle_id%TYPE,
    p_od          IN DATE DEFAULT NULL,
    p_do          IN DATE DEFAULT NULL
  ) RETURN NUMBER IS
    l_suma  NUMBER;
  BEGIN
    SELECT NVL(SUM(cost), 0)
      INTO l_suma
      FROM maintenance
     WHERE vehicle_id = p_vehicle_id
       AND (p_od IS NULL OR TRUNC(start_date) >= TRUNC(p_od))
       AND (p_do IS NULL OR TRUNC(start_date) <= TRUNC(p_do));
    RETURN l_suma;
  END f_koszt_serwisu;


  /* =================== PROCEDURY PUBLICZNE =================== */

  -- P1
  PROCEDURE p_skieruj_do_serwisu (
    p_vehicle_id      IN  vehicles.vehicle_id%TYPE,
    p_typ_id          IN  maintenance_types.maintenance_type_id%TYPE,
    p_employee_id     IN  employees.user_id%TYPE,
    p_opis            IN  maintenance.description%TYPE DEFAULT NULL,
    o_maintenance_id  OUT maintenance.maintenance_id%TYPE
  ) IS
    l_v        vehicles%ROWTYPE;
    l_typ      maintenance_types.type_name%TYPE;
    l_ile      NUMBER;
    l_kod      NUMBER;
    l_msg      VARCHAR2(4000);
    l_bt       VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_serwis;

    l_v := pobierz_pojazd(p_vehicle_id);

    IF l_v.vehicle_status = 'MAINTENANCE' THEN
      RAISE_APPLICATION_ERROR(-20011, 'Pojazd ' || l_v.license_plate || ' jest już w serwisie.');
    ELSIF l_v.vehicle_status <> 'AVAILABLE' THEN
      RAISE_APPLICATION_ERROR(-20010,
        'Pojazd ' || l_v.license_plate || ' ma status ' || l_v.vehicle_status
        || ' – do serwisu można skierować tylko auto dostępne.');
    END IF;

    BEGIN
      SELECT type_name INTO l_typ FROM maintenance_types WHERE maintenance_type_id = p_typ_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono typu serwisu o ID ' || p_typ_id || '.');
    END;

    SELECT COUNT(*) INTO l_ile FROM employees WHERE user_id = p_employee_id;
    IF l_ile = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pracownika o ID ' || p_employee_id || '.');
    END IF;

    INSERT INTO maintenance (vehicle_id, maintenance_type_id, employee_id, start_date,
                             mileage_at_service, description)
    VALUES (p_vehicle_id, p_typ_id, p_employee_id, TRUNC(SYSDATE),
            l_v.mileage, NVL(p_opis, l_typ))
    RETURNING maintenance_id INTO o_maintenance_id;

    UPDATE vehicles SET vehicle_status = 'MAINTENANCE' WHERE vehicle_id = p_vehicle_id;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_serwis;
      p_loguj_blad('PKG_FLOTA.P_SKIERUJ_DO_SERWISU', l_kod, l_msg, l_bt);
      RAISE;
  END p_skieruj_do_serwisu;

  -- P2
  PROCEDURE p_zakoncz_serwis (
    p_maintenance_id  IN maintenance.maintenance_id%TYPE,
    p_koszt           IN maintenance.cost%TYPE,
    p_uwagi           IN VARCHAR2 DEFAULT NULL
  ) IS
    l_m        maintenance%ROWTYPE;
    l_otwarte  NUMBER;
    l_kod      NUMBER;
    l_msg      VARCHAR2(4000);
    l_bt       VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_koniec_serwisu;

    BEGIN
      SELECT * INTO l_m FROM maintenance WHERE maintenance_id = p_maintenance_id FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono serwisu nr ' || p_maintenance_id || '.');
    END;

    IF l_m.end_date IS NOT NULL THEN
      RAISE_APPLICATION_ERROR(-20011,
        'Serwis nr ' || p_maintenance_id || ' został już zakończony '
        || TO_CHAR(l_m.end_date, 'YYYY-MM-DD') || '.');
    END IF;

    IF p_koszt IS NULL OR p_koszt < 0 THEN
      RAISE_APPLICATION_ERROR(-20012, 'Koszt serwisu musi być liczbą nieujemną.');
    END IF;

    UPDATE maintenance
       SET end_date    = GREATEST(TRUNC(SYSDATE), TRUNC(start_date)),
           cost        = p_koszt,
           description = SUBSTR(CASE WHEN p_uwagi IS NULL THEN description
                                     ELSE description || ' | ' || p_uwagi END, 1, 400)
     WHERE maintenance_id = p_maintenance_id;

    -- auto wraca do floty, jeśli nie ma innych otwartych serwisów
    SELECT COUNT(*)
      INTO l_otwarte
      FROM maintenance
     WHERE vehicle_id = l_m.vehicle_id
       AND end_date IS NULL;

    IF l_otwarte = 0 THEN
      UPDATE vehicles
         SET vehicle_status = 'AVAILABLE'
       WHERE vehicle_id = l_m.vehicle_id
         AND vehicle_status = 'MAINTENANCE';
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_koniec_serwisu;
      p_loguj_blad('PKG_FLOTA.P_ZAKONCZ_SERWIS', l_kod, l_msg, l_bt);
      RAISE;
  END p_zakoncz_serwis;

  -- P3
  PROCEDURE p_przenies_auto (
    p_vehicle_id         IN vehicles.vehicle_id%TYPE,
    p_branch_docelowy    IN branches.branch_id%TYPE
  ) IS
    l_v        vehicles%ROWTYPE;
    l_ile      NUMBER;
    l_kod      NUMBER;
    l_msg      VARCHAR2(4000);
    l_bt       VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_przeniesienie;

    l_v := pobierz_pojazd(p_vehicle_id);

    IF l_v.vehicle_status <> 'AVAILABLE' THEN
      RAISE_APPLICATION_ERROR(-20010,
        'Pojazd ' || l_v.license_plate || ' ma status ' || l_v.vehicle_status
        || ' – przenieść można tylko auto dostępne.');
    END IF;

    SELECT COUNT(*) INTO l_ile FROM branches WHERE branch_id = p_branch_docelowy;
    IF l_ile = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono oddziału o ID ' || p_branch_docelowy || '.');
    END IF;

    IF l_v.branch_id = p_branch_docelowy THEN
      RAISE_APPLICATION_ERROR(-20012, 'Pojazd ' || l_v.license_plate || ' już jest w tym oddziale.');
    END IF;

    l_ile := przyszle_rezerwacje(p_vehicle_id);
    IF l_ile > 0 THEN
      RAISE_APPLICATION_ERROR(-20013,
        'Pojazd ' || l_v.license_plate || ' ma ' || l_ile
        || ' przyszłych rezerwacji w obecnym oddziale – najpierw je anuluj.');
    END IF;

    UPDATE vehicles SET branch_id = p_branch_docelowy WHERE vehicle_id = p_vehicle_id;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_przeniesienie;
      p_loguj_blad('PKG_FLOTA.P_PRZENIES_AUTO', l_kod, l_msg, l_bt);
      RAISE;
  END p_przenies_auto;

  -- P4: zamiana wyjątku systemowego DUP_VAL_ON_INDEX na czytelny komunikat
  PROCEDURE p_dodaj_pojazd (
    p_branch_id        IN  branches.branch_id%TYPE,
    p_vehicle_type_id  IN  vehicle_types.vehicle_type_id%TYPE,
    p_nr_rej           IN  vehicles.license_plate%TYPE,
    p_vin              IN  VARCHAR2,
    p_kolor            IN  vehicles.color%TYPE DEFAULT NULL,
    p_przebieg         IN  vehicles.mileage%TYPE DEFAULT 0,
    o_vehicle_id       OUT vehicles.vehicle_id%TYPE
  ) IS
    l_ile   NUMBER;
    l_kod   NUMBER;
    l_msg   VARCHAR2(4000);
    l_bt    VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_nowy_pojazd;

    IF p_nr_rej IS NULL OR TRIM(p_nr_rej) IS NULL THEN
      RAISE_APPLICATION_ERROR(-20012, 'Numer rejestracyjny jest wymagany.');
    END IF;

    IF p_vin IS NULL OR NOT REGEXP_LIKE(UPPER(TRIM(p_vin)), '^[A-HJ-NPR-Z0-9]{17}$') THEN
      RAISE_APPLICATION_ERROR(-20012,
        'VIN musi mieć 17 znaków (cyfry i litery bez I, O, Q).');
    END IF;

    IF NVL(p_przebieg, 0) < 0 THEN
      RAISE_APPLICATION_ERROR(-20012, 'Przebieg nie może być ujemny.');
    END IF;

    SELECT COUNT(*) INTO l_ile FROM branches WHERE branch_id = p_branch_id;
    IF l_ile = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono oddziału o ID ' || p_branch_id || '.');
    END IF;

    SELECT COUNT(*) INTO l_ile FROM vehicle_types WHERE vehicle_type_id = p_vehicle_type_id;
    IF l_ile = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono typu pojazdu o ID ' || p_vehicle_type_id || '.');
    END IF;

    INSERT INTO vehicles (branch_id, vehicle_type_id, license_plate, vin, color,
                          mileage, vehicle_status)
    VALUES (p_branch_id, p_vehicle_type_id, UPPER(TRIM(p_nr_rej)), UPPER(TRIM(p_vin)),
            p_kolor, NVL(p_przebieg, 0), 'AVAILABLE')
    RETURNING vehicle_id INTO o_vehicle_id;

  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_nowy_pojazd;
      p_loguj_blad('PKG_FLOTA.P_DODAJ_POJAZD', l_kod, l_msg, l_bt);
      RAISE_APPLICATION_ERROR(-20012,
        'Pojazd o numerze ' || UPPER(TRIM(p_nr_rej)) || ' lub VIN ' || UPPER(TRIM(p_vin))
        || ' już istnieje w bazie.');
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_nowy_pojazd;
      p_loguj_blad('PKG_FLOTA.P_DODAJ_POJAZD', l_kod, l_msg, l_bt);
      RAISE;
  END p_dodaj_pojazd;

  -- P5
  PROCEDURE p_wycofaj_pojazd (
    p_vehicle_id  IN vehicles.vehicle_id%TYPE
  ) IS
    l_v     vehicles%ROWTYPE;
    l_ile   NUMBER;
    l_kod   NUMBER;
    l_msg   VARCHAR2(4000);
    l_bt    VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_wycofanie;

    l_v := pobierz_pojazd(p_vehicle_id);

    IF l_v.vehicle_status IN ('RENTED', 'RETIRED') THEN
      RAISE_APPLICATION_ERROR(-20010,
        'Nie można wycofać pojazdu ' || l_v.license_plate || ' (status: ' || l_v.vehicle_status || ').');
    END IF;

    SELECT COUNT(*) INTO l_ile
      FROM maintenance WHERE vehicle_id = p_vehicle_id AND end_date IS NULL;
    IF l_ile > 0 THEN
      RAISE_APPLICATION_ERROR(-20011,
        'Pojazd ' || l_v.license_plate || ' ma otwarty serwis – najpierw go zakończ.');
    END IF;

    l_ile := przyszle_rezerwacje(p_vehicle_id);
    IF l_ile > 0 THEN
      RAISE_APPLICATION_ERROR(-20013,
        'Pojazd ' || l_v.license_plate || ' ma ' || l_ile
        || ' przyszłych rezerwacji – najpierw je anuluj.');
    END IF;

    UPDATE vehicles SET vehicle_status = 'RETIRED' WHERE vehicle_id = p_vehicle_id;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_wycofanie;
      p_loguj_blad('PKG_FLOTA.P_WYCOFAJ_POJAZD', l_kod, l_msg, l_bt);
      RAISE;
  END p_wycofaj_pojazd;

  -- P6: zagnieżdżone pętle kursorowe (oddziały -> auta) + kursor na kolekcji TABLE()
  PROCEDURE p_drukuj_raport_floty (
    p_od  IN DATE,
    p_do  IN DATE
  ) IS
    CURSOR c_oddzialy IS
      SELECT branch_id, branch_name FROM branches ORDER BY branch_name;

    CURSOR c_auta (cp_oddzial NUMBER) IS
      SELECT *
        FROM TABLE(pkg_flota.f_oblozenie_floty(p_od, p_do, cp_oddzial));

    l_rap         t_raport_oddzialu;
    l_saldo_suma  NUMBER := 0;
    l_pasek       VARCHAR2(20);
    l_kod         NUMBER;
    l_msg         VARCHAR2(4000);
    l_bt          VARCHAR2(4000);
  BEGIN
    sprawdz_okres(p_od, p_do);

    DBMS_OUTPUT.PUT_LINE('RAPORT FLOTY ' || TO_CHAR(p_od, 'YYYY-MM-DD')
                         || ' – ' || TO_CHAR(p_do, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 90, '='));

    FOR r_odd IN c_oddzialy LOOP
      l_rap := f_raport_oddzialu(r_odd.branch_id, p_od, p_do);
      l_saldo_suma := l_saldo_suma + l_rap.saldo();

      DBMS_OUTPUT.PUT_LINE('');
      DBMS_OUTPUT.PUT_LINE('ODDZIAŁ: ' || UPPER(r_odd.branch_name));
      DBMS_OUTPUT.PUT_LINE('  wypożyczeń: ' || l_rap.liczba_wypozyczen
        || ' | najem: '   || TO_CHAR(l_rap.przychod_najem, 'FM9999990.00')
        || ' | szkody: '  || TO_CHAR(l_rap.oplaty_szkody,  'FM9999990.00')
        || ' | serwis: -' || TO_CHAR(l_rap.koszt_serwisu,  'FM9999990.00')
        || ' | saldo: '   || TO_CHAR(l_rap.saldo(),        'FM9999990.00') || ' zł'
        || ' | śr./wyp.: '|| TO_CHAR(l_rap.srednia_na_wypozyczenie(), 'FM9999990.00') || ' zł');

      FOR r_auto IN c_auta(r_odd.branch_id) LOOP
        l_pasek := RPAD('#', GREATEST(1, ROUND(r_auto.oblozenie_proc / 10)), '#');
        IF r_auto.dni_wynajmu = 0 THEN
          l_pasek := '';
        END IF;

        DBMS_OUTPUT.PUT_LINE('    ' || RPAD(r_auto.nr_rejestracyjny, 10)
          || RPAD(r_auto.pojazd, 20)
          || LPAD(r_auto.dni_wynajmu, 4) || ' dni '
          || LPAD(TO_CHAR(r_auto.oblozenie_proc, 'FM990.0'), 6) || '% '
          || RPAD(NVL(l_pasek, ' '), 11)
          || LPAD(TO_CHAR(r_auto.przychod, 'FM9999990.00'), 10) || ' zł');
      END LOOP;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 90, '='));
    DBMS_OUTPUT.PUT_LINE('SALDO WSZYSTKICH ODDZIAŁÓW: ' || TO_CHAR(l_saldo_suma, 'FM9999990.00') || ' zł');

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('AUTA DO PRZEGLĄDU (<= 1000 km):');
    FOR r_p IN (SELECT * FROM TABLE(pkg_flota.f_auta_do_przegladu(1000))) LOOP
      DBMS_OUTPUT.PUT_LINE('    ' || RPAD(r_p.nr_rejestracyjny, 10) || RPAD(r_p.pojazd, 20)
        || RPAD(r_p.oddzial, 20) || LPAD(r_p.km_do_przegladu, 8) || ' km  ' || r_p.pilnosc);
    END LOOP;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      p_loguj_blad('PKG_FLOTA.P_DRUKUJ_RAPORT_FLOTY', l_kod, l_msg, l_bt);
      RAISE;
  END p_drukuj_raport_floty;

END pkg_flota;
/
SHOW ERRORS
