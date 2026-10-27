/* =====================================================================
   PAKIET 4: PKG_ANALITYKA – statystyki, rankingi, raporty (pod wykresy APEX)
   Wymaga: 01, 02, 04 (PKG_FLOTA), 06 (PKG_KLIENCI)

   Zawartość skryptu:
     1. Usunięcie starego pakietu i typów
     2. Typy obiektowe i kolekcje
     3. Specyfikacja pakietu
     4. Ciało pakietu

   Funkcje (5) – wszystkie zwracają typy SQL, więc w APEX wystarczy
   SELECT * FROM TABLE(pkg_analityka.f_...(...)) jako źródło wykresu/raportu:
     F1 f_ranking_modeli         – RANK() + RATIO_TO_REPORT()   -> T_RANKING_MODELU_TAB
     F2 f_top_klienci            – DENSE_RANK() + poziom z PKG_KLIENCI -> T_TOP_KLIENT_TAB
     F3 f_przychod_miesieczny    – LAG() + suma narastająca, miesiące bez ruchu też -> T_PRZYCHOD_MIESIACA_TAB
     F4 f_statystyki_dashboard   – kafelki KPI -> obiekt T_STATYSTYKI
     F5 f_rozklad                – dynamiczny SQL + zmienna kursorowa (SYS_REFCURSOR) -> T_PUNKT_TAB
   Procedury (4):
     P1 p_raport_miesieczny      – raport zarządczy za miesiąc (DBMS_OUTPUT)
     P2 p_porownaj_oddzialy      – ranking oddziałów (korzysta z PKG_FLOTA)
     P3 p_raport_json            – raport w JSON (JSON_OBJECT / JSON_ARRAYAGG) -> CLOB
     P4 p_wykryj_anomalie        – alerty: przeterminowane zwroty, nierentowne auta, ...

   Kody błędów:
     -20002 nieprawidłowy okres     -20030 nieprawidłowy parametr
   ===================================================================== */


/* =====================================================================
   1. USUNIĘCIE STAREGO PAKIETU I TYPÓW
   ===================================================================== */
BEGIN
  FOR p IN (SELECT object_name FROM user_objects
             WHERE object_type = 'PACKAGE' AND object_name = 'PKG_ANALITYKA')
  LOOP
    EXECUTE IMMEDIATE 'DROP PACKAGE pkg_analityka';
  END LOOP;

  FOR t IN (SELECT type_name FROM user_types
             WHERE type_name IN ('T_RANKING_MODELU_TAB','T_TOP_KLIENT_TAB',
                                 'T_PRZYCHOD_MIESIACA_TAB','T_PUNKT_TAB',
                                 'T_RANKING_MODELU','T_TOP_KLIENT','T_PRZYCHOD_MIESIACA',
                                 'T_PUNKT','T_STATYSTYKI')
             ORDER BY CASE WHEN type_name LIKE '%TAB' THEN 0 ELSE 1 END)
  LOOP
    EXECUTE IMMEDIATE 'DROP TYPE ' || t.type_name || ' FORCE';
  END LOOP;
END;
/


/* =====================================================================
   2. TYPY OBIEKTOWE I KOLEKCJE
   ===================================================================== */
CREATE OR REPLACE TYPE t_ranking_modelu AS OBJECT (
  pozycja            NUMBER,
  marka_model        VARCHAR2(110 CHAR),
  kategoria          VARCHAR2(10 CHAR),
  liczba_wypozyczen  NUMBER,
  dni_wynajmu        NUMBER,
  przychod           NUMBER(12,2),
  udzial_proc        NUMBER(5,1)
);
/
CREATE OR REPLACE TYPE t_ranking_modelu_tab AS TABLE OF t_ranking_modelu;
/

CREATE OR REPLACE TYPE t_top_klient AS OBJECT (
  pozycja            NUMBER,
  customer_id        NUMBER,
  klient             VARCHAR2(110 CHAR),
  liczba_wypozyczen  NUMBER,
  wydano             NUMBER(12,2),
  srednia_wartosc    NUMBER(12,2),
  poziom             VARCHAR2(12 CHAR)
);
/
CREATE OR REPLACE TYPE t_top_klient_tab AS TABLE OF t_top_klient;
/

CREATE OR REPLACE TYPE t_przychod_miesiaca AS OBJECT (
  miesiac            DATE,
  etykieta           VARCHAR2(7 CHAR),       -- RRRR-MM (oś X wykresu)
  liczba_wypozyczen  NUMBER,
  przychod           NUMBER(12,2),
  przychod_poprz     NUMBER(12,2),
  zmiana_proc        NUMBER(7,1),
  narastajaco        NUMBER(14,2)
);
/
CREATE OR REPLACE TYPE t_przychod_miesiaca_tab AS TABLE OF t_przychod_miesiaca;
/

-- Uniwersalny punkt wykresu (etykieta + wartość) – np. wykres kołowy
CREATE OR REPLACE TYPE t_punkt AS OBJECT (
  etykieta  VARCHAR2(60 CHAR),
  wartosc   NUMBER(14,2)
);
/
CREATE OR REPLACE TYPE t_punkt_tab AS TABLE OF t_punkt;
/

-- Kafelki KPI dashboardu
CREATE OR REPLACE TYPE t_statystyki AS OBJECT (
  liczba_aut            NUMBER,
  aut_dostepnych        NUMBER,
  aut_wypozyczonych     NUMBER,
  aut_w_serwisie        NUMBER,
  aktywne_wypozyczenia  NUMBER,
  przyszle_rezerwacje   NUMBER,
  liczba_klientow       NUMBER,
  przychod_30_dni       NUMBER(12,2),
  przychod_rok          NUMBER(12,2),
  sredni_czas_wynajmu   NUMBER(6,1),
  srednia_wartosc       NUMBER(12,2),
  wskaznik_szkod_proc   NUMBER(5,1),
  MEMBER FUNCTION wykorzystanie_floty_proc RETURN NUMBER
);
/
SHOW ERRORS

CREATE OR REPLACE TYPE BODY t_statystyki AS
  MEMBER FUNCTION wykorzystanie_floty_proc RETURN NUMBER IS
  BEGIN
    IF NVL(liczba_aut, 0) = 0 THEN
      RETURN 0;
    END IF;
    RETURN ROUND(aut_wypozyczonych * 100 / liczba_aut, 1);
  END wykorzystanie_floty_proc;
END;
/
SHOW ERRORS


/* =====================================================================
   3. SPECYFIKACJA PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE pkg_analityka AS

  e_zle_daty      EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zle_daty,     -20002);
  e_zly_parametr  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zly_parametr, -20030);

  /* ---------------- FUNKCJE ---------------- */

  -- F1: najpopularniejsze modele (wypożyczenia rozpoczęte w okresie, bez rezerwacji i anulowanych)
  FUNCTION f_ranking_modeli (
    p_od   IN DATE,
    p_do   IN DATE,
    p_top  IN PLS_INTEGER DEFAULT 10
  ) RETURN t_ranking_modelu_tab;

  -- F2: klienci z największymi wydatkami (najem + opłaty za szkody); okres opcjonalny
  FUNCTION f_top_klienci (
    p_top  IN PLS_INTEGER DEFAULT 5,
    p_od   IN DATE DEFAULT NULL,
    p_do   IN DATE DEFAULT NULL
  ) RETURN t_top_klient_tab;

  -- F3: przychód miesiąc po miesiącu ze zmianą m/m i sumą narastającą
  FUNCTION f_przychod_miesieczny (
    p_od         IN DATE,
    p_do         IN DATE,
    p_branch_id  IN branches.branch_id%TYPE DEFAULT NULL
  ) RETURN t_przychod_miesiaca_tab;

  -- F4: KPI na dziś
  FUNCTION f_statystyki_dashboard RETURN t_statystyki;

  -- F5: rozkład wg wymiaru: KATEGORIA, PALIWO, DZIEN_TYGODNIA, ODDZIAL, METODA_PLATNOSCI
  FUNCTION f_rozklad (
    p_wymiar  IN VARCHAR2,
    p_od      IN DATE DEFAULT NULL,
    p_do      IN DATE DEFAULT NULL
  ) RETURN t_punkt_tab;

  /* ---------------- PROCEDURY ---------------- */

  -- P1
  PROCEDURE p_raport_miesieczny (
    p_rok      IN PLS_INTEGER,
    p_miesiac  IN PLS_INTEGER
  );

  -- P2
  PROCEDURE p_porownaj_oddzialy (
    p_od  IN DATE,
    p_do  IN DATE
  );

  -- P3
  PROCEDURE p_raport_json (
    p_od    IN  DATE,
    p_do    IN  DATE,
    o_json  OUT CLOB
  );

  -- P4: wypisuje alerty i zwraca ich liczbę
  PROCEDURE p_wykryj_anomalie (
    p_dni_postoju  IN  PLS_INTEGER DEFAULT 60,
    o_liczba       OUT PLS_INTEGER
  );

END pkg_analityka;
/
SHOW ERRORS


/* =====================================================================
   4. CIAŁO PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE BODY pkg_analityka AS

  /* =================== ELEMENTY PRYWATNE =================== */

  PROCEDURE sprawdz_okres (p_od IN DATE, p_do IN DATE) IS
  BEGIN
    IF p_od IS NULL OR p_do IS NULL OR TRUNC(p_do) < TRUNC(p_od) THEN
      RAISE_APPLICATION_ERROR(-20002,
        'Nieprawidłowy okres: data końcowa nie może być wcześniejsza niż początkowa.');
    END IF;
  END sprawdz_okres;

  PROCEDURE sprawdz_top (p_top IN PLS_INTEGER) IS
  BEGIN
    IF p_top IS NULL OR p_top < 1 THEN
      RAISE_APPLICATION_ERROR(-20030, 'Parametr TOP musi być liczbą >= 1.');
    END IF;
  END sprawdz_top;

  FUNCTION kwota (p_wartosc IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(NVL(p_wartosc, 0), 'FM9999990.00') || ' zł';
  END kwota;


  /* =================== FUNKCJE PUBLICZNE =================== */

  -- F1
  FUNCTION f_ranking_modeli (
    p_od   IN DATE,
    p_do   IN DATE,
    p_top  IN PLS_INTEGER DEFAULT 10
  ) RETURN t_ranking_modelu_tab IS
    l_wynik  t_ranking_modelu_tab;
  BEGIN
    sprawdz_okres(p_od, p_do);
    sprawdz_top(p_top);

    SELECT t_ranking_modelu(pozycja, auto, kategoria, liczba, dni, przychod, udzial)
      BULK COLLECT INTO l_wynik
      FROM (SELECT RANK() OVER (ORDER BY COUNT(*) DESC, SUM(NVL(b.total_cost, 0)) DESC) AS pozycja,
                   m.make_name || ' ' || vt.model_name                             AS auto,
                   vt.category                                                     AS kategoria,
                   COUNT(*)                                                        AS liczba,
                   SUM(CASE WHEN b.booking_status = 'COMPLETED'
                              THEN TRUNC(b.actual_return_date)
                            ELSE GREATEST(TRUNC(b.planned_end_date), TRUNC(SYSDATE))
                       END - TRUNC(b.start_date))                                  AS dni,
                   SUM(NVL(b.total_cost, 0))                                       AS przychod,
                   ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1)               AS udzial
              FROM bookings b
              JOIN vehicles v       ON v.vehicle_id       = b.vehicle_id
              JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
              JOIN makes m          ON m.make_id          = vt.make_id
             WHERE b.booking_status IN ('ACTIVE', 'COMPLETED')
               AND TRUNC(b.start_date) BETWEEN TRUNC(p_od) AND TRUNC(p_do)
             GROUP BY m.make_name, vt.model_name, vt.category)
     WHERE pozycja <= p_top
     ORDER BY pozycja, auto;

    RETURN l_wynik;
  END f_ranking_modeli;

  -- F2
  FUNCTION f_top_klienci (
    p_top  IN PLS_INTEGER DEFAULT 5,
    p_od   IN DATE DEFAULT NULL,
    p_do   IN DATE DEFAULT NULL
  ) RETURN t_top_klient_tab IS
    l_od     DATE := NVL(TRUNC(p_od), DATE '1900-01-01');
    l_do     DATE := NVL(TRUNC(p_do), DATE '9999-12-31');
    l_wynik  t_top_klient_tab;
  BEGIN
    sprawdz_top(p_top);
    sprawdz_okres(l_od, l_do);

    SELECT t_top_klient(pozycja, customer_id, klient, liczba, wydano,
                        ROUND(wydano / NULLIF(liczba, 0), 2),
                        pkg_klienci.f_poziom_lojalnosci(customer_id))
      BULK COLLECT INTO l_wynik
      FROM (SELECT DENSE_RANK() OVER (ORDER BY w.wydano DESC) AS pozycja,
                   c.user_id                                  AS customer_id,
                   u.first_name || ' ' || u.last_name         AS klient,
                   NVL(k.liczba, 0)                           AS liczba,
                   w.wydano
              FROM customers c
              JOIN users u ON u.user_id = c.user_id
              JOIN (SELECT b.customer_id, SUM(t.amount) AS wydano
                      FROM transactions t
                      JOIN bookings b ON b.booking_id = t.booking_id
                     WHERE t.transaction_type IN ('PAYMENT', 'DAMAGE_FEE')
                       AND TRUNC(t.transaction_date) BETWEEN l_od AND l_do
                     GROUP BY b.customer_id) w
                ON w.customer_id = c.user_id
              LEFT JOIN (SELECT customer_id, COUNT(*) AS liczba
                           FROM bookings
                          WHERE booking_status <> 'CANCELLED'
                            AND TRUNC(start_date) BETWEEN l_od AND l_do
                          GROUP BY customer_id) k
                ON k.customer_id = c.user_id)
     WHERE pozycja <= p_top
     ORDER BY pozycja, klient;

    RETURN l_wynik;
  END f_top_klienci;

  -- F3: generator miesięcy (CONNECT BY LEVEL) + LAG + SUM() OVER
  FUNCTION f_przychod_miesieczny (
    p_od         IN DATE,
    p_do         IN DATE,
    p_branch_id  IN branches.branch_id%TYPE DEFAULT NULL
  ) RETURN t_przychod_miesiaca_tab IS
    l_pocz   DATE;
    l_kon    DATE;
    l_wynik  t_przychod_miesiaca_tab;
  BEGIN
    sprawdz_okres(p_od, p_do);
    l_pocz := TRUNC(p_od, 'MM');
    l_kon  := TRUNC(p_do, 'MM');

    IF MONTHS_BETWEEN(l_kon, l_pocz) > 120 THEN
      RAISE_APPLICATION_ERROR(-20030, 'Maksymalny zakres raportu to 10 lat.');
    END IF;

    SELECT t_przychod_miesiaca(
             mies, TO_CHAR(mies, 'YYYY-MM'), liczba, przychod, poprz,
             CASE WHEN poprz > 0 THEN ROUND((przychod - poprz) * 100 / poprz, 1) END,
             narast)
      BULK COLLECT INTO l_wynik
      FROM (SELECT k.mies,
                   NVL(w.liczba, 0)                                            AS liczba,
                   NVL(p.przychod, 0)                                          AS przychod,
                   LAG(NVL(p.przychod, 0)) OVER (ORDER BY k.mies)              AS poprz,
                   SUM(NVL(p.przychod, 0)) OVER (ORDER BY k.mies
                                                 ROWS UNBOUNDED PRECEDING)     AS narast
              FROM (SELECT ADD_MONTHS(l_pocz, LEVEL - 1) AS mies
                      FROM dual
                   CONNECT BY LEVEL <= MONTHS_BETWEEN(l_kon, l_pocz) + 1) k
              LEFT JOIN (SELECT TRUNC(t.transaction_date, 'MM') AS mies, SUM(t.amount) AS przychod
                           FROM transactions t
                           JOIN bookings b ON b.booking_id = t.booking_id
                           JOIN vehicles v ON v.vehicle_id = b.vehicle_id
                          WHERE t.transaction_type IN ('PAYMENT', 'DAMAGE_FEE')
                            AND (p_branch_id IS NULL OR v.branch_id = p_branch_id)
                          GROUP BY TRUNC(t.transaction_date, 'MM')) p
                ON p.mies = k.mies
              LEFT JOIN (SELECT TRUNC(b.start_date, 'MM') AS mies, COUNT(*) AS liczba
                           FROM bookings b
                           JOIN vehicles v ON v.vehicle_id = b.vehicle_id
                          WHERE b.booking_status <> 'CANCELLED'
                            AND (p_branch_id IS NULL OR v.branch_id = p_branch_id)
                          GROUP BY TRUNC(b.start_date, 'MM')) w
                ON w.mies = k.mies)
     ORDER BY mies;

    RETURN l_wynik;
  END f_przychod_miesieczny;

  -- F4
  FUNCTION f_statystyki_dashboard RETURN t_statystyki IS
    l_aut        NUMBER;
    l_dostepne   NUMBER;
    l_wypoz      NUMBER;
    l_serwis     NUMBER;
    l_aktywne    NUMBER;
    l_przyszle   NUMBER;
    l_klienci    NUMBER;
    l_p30        NUMBER;
    l_prok       NUMBER;
    l_czas       NUMBER;
    l_srednia    NUMBER;
    l_szkody     NUMBER;
  BEGIN
    SELECT COUNT(*),
           COUNT(CASE WHEN vehicle_status = 'AVAILABLE'   THEN 1 END),
           COUNT(CASE WHEN vehicle_status = 'RENTED'      THEN 1 END),
           COUNT(CASE WHEN vehicle_status = 'MAINTENANCE' THEN 1 END)
      INTO l_aut, l_dostepne, l_wypoz, l_serwis
      FROM vehicles
     WHERE vehicle_status <> 'RETIRED';

    SELECT COUNT(CASE WHEN booking_status = 'ACTIVE'   THEN 1 END),
           COUNT(CASE WHEN booking_status = 'RESERVED' THEN 1 END)
      INTO l_aktywne, l_przyszle
      FROM bookings;

    SELECT COUNT(*) INTO l_klienci FROM customers;

    SELECT NVL(SUM(CASE WHEN transaction_date >= TRUNC(SYSDATE) - 30      THEN amount END), 0),
           NVL(SUM(CASE WHEN transaction_date >= TRUNC(SYSDATE, 'YYYY')   THEN amount END), 0)
      INTO l_p30, l_prok
      FROM transactions
     WHERE transaction_type IN ('PAYMENT', 'DAMAGE_FEE');

    -- zakończone wypożyczenia: średni czas, średnia wartość, odsetek ze szkodą
    SELECT NVL(ROUND(AVG(TRUNC(b.actual_return_date) - TRUNC(b.start_date)), 1), 0),
           NVL(ROUND(AVG(b.total_cost), 2), 0),
           NVL(ROUND(100 * COUNT(d.booking_id) / NULLIF(COUNT(*), 0), 1), 0)
      INTO l_czas, l_srednia, l_szkody
      FROM bookings b
      LEFT JOIN (SELECT DISTINCT booking_id FROM damages) d
        ON d.booking_id = b.booking_id
     WHERE b.booking_status = 'COMPLETED';

    RETURN t_statystyki(l_aut, l_dostepne, l_wypoz, l_serwis, l_aktywne, l_przyszle, l_klienci,
                        l_p30, l_prok, l_czas, l_srednia, l_szkody);
  END f_statystyki_dashboard;

  -- F5: SQL budowany z białej listy wymiarów (bez ryzyka SQL injection),
  --     otwierany jako zmienna kursorowa z parametrami wiązanymi
  FUNCTION f_rozklad (
    p_wymiar  IN VARCHAR2,
    p_od      IN DATE DEFAULT NULL,
    p_do      IN DATE DEFAULT NULL
  ) RETURN t_punkt_tab IS
    TYPE t_etykiety IS TABLE OF VARCHAR2(60);
    TYPE t_wartosci IS TABLE OF NUMBER;

    l_wymiar     VARCHAR2(30) := UPPER(TRIM(p_wymiar));
    l_od         DATE := NVL(TRUNC(p_od), DATE '1900-01-01');
    l_do         DATE := NVL(TRUNC(p_do), DATE '9999-12-31');
    l_sql        VARCHAR2(2000);
    l_kursor     SYS_REFCURSOR;
    l_etykiety   t_etykiety;
    l_wartosci   t_wartosci;
    l_wynik      t_punkt_tab := t_punkt_tab();

    -- wspólne fragmenty zapytań
    c_rezerwacje CONSTANT VARCHAR2(500) :=
      ' FROM bookings b'
      || ' JOIN vehicles v ON v.vehicle_id = b.vehicle_id'
      || ' JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id'
      || ' WHERE b.booking_status <> ''CANCELLED'''
      || ' AND TRUNC(b.start_date) BETWEEN :p_od AND :p_do';
    c_wplaty CONSTANT VARCHAR2(500) :=
      ' FROM transactions t'
      || ' JOIN bookings b ON b.booking_id = t.booking_id'
      || ' JOIN vehicles v ON v.vehicle_id = b.vehicle_id'
      || ' JOIN branches br ON br.branch_id = v.branch_id'
      || ' WHERE t.transaction_type IN (''PAYMENT'', ''DAMAGE_FEE'')'
      || ' AND TRUNC(t.transaction_date) BETWEEN :p_od AND :p_do';
  BEGIN
    sprawdz_okres(l_od, l_do);

    l_sql := CASE l_wymiar
      WHEN 'KATEGORIA' THEN
        'SELECT vt.category, COUNT(*)' || c_rezerwacje || ' GROUP BY vt.category ORDER BY 2 DESC, 1'
      WHEN 'PALIWO' THEN
        'SELECT vt.fuel_type, COUNT(*)' || c_rezerwacje || ' GROUP BY vt.fuel_type ORDER BY 2 DESC, 1'
      WHEN 'DZIEN_TYGODNIA' THEN
        'SELECT TO_CHAR(b.start_date, ''FMDay'', ''NLS_DATE_LANGUAGE=POLISH''), COUNT(*)'
        || c_rezerwacje
        || ' GROUP BY TO_CHAR(b.start_date, ''FMDay'', ''NLS_DATE_LANGUAGE=POLISH''),'
        || ' TRUNC(b.start_date) - TRUNC(b.start_date, ''IW'')'
        || ' ORDER BY TRUNC(b.start_date) - TRUNC(b.start_date, ''IW'')'
      WHEN 'ODDZIAL' THEN
        'SELECT br.branch_name, SUM(t.amount)' || c_wplaty || ' GROUP BY br.branch_name ORDER BY 2 DESC, 1'
      WHEN 'METODA_PLATNOSCI' THEN
        'SELECT t.payment_method, SUM(t.amount)' || c_wplaty || ' GROUP BY t.payment_method ORDER BY 2 DESC, 1'
    END;

    IF l_sql IS NULL THEN
      RAISE_APPLICATION_ERROR(-20030,
        'Nieznany wymiar "' || p_wymiar || '". Dozwolone: KATEGORIA, PALIWO, DZIEN_TYGODNIA, '
        || 'ODDZIAL, METODA_PLATNOSCI.');
    END IF;

    OPEN l_kursor FOR l_sql USING l_od, l_do;
    FETCH l_kursor BULK COLLECT INTO l_etykiety, l_wartosci;
    CLOSE l_kursor;

    FOR i IN 1 .. l_etykiety.COUNT LOOP
      l_wynik.EXTEND;
      l_wynik(l_wynik.LAST) := t_punkt(l_etykiety(i), l_wartosci(i));
    END LOOP;

    RETURN l_wynik;
  EXCEPTION
    WHEN OTHERS THEN
      IF l_kursor%ISOPEN THEN CLOSE l_kursor; END IF;
      RAISE;
  END f_rozklad;


  /* =================== PROCEDURY PUBLICZNE =================== */

  -- P1
  PROCEDURE p_raport_miesieczny (
    p_rok      IN PLS_INTEGER,
    p_miesiac  IN PLS_INTEGER
  ) IS
    l_pocz      DATE;
    l_kon       DATE;
    l_mies      t_przychod_miesiaca_tab;
    l_szkody    NUMBER;
    l_koszt_sz  NUMBER;
    l_nowe      NUMBER;
    l_ile       PLS_INTEGER;
    l_kod       NUMBER;
    l_msg       VARCHAR2(4000);
    l_bt        VARCHAR2(4000);
  BEGIN
    IF p_miesiac IS NULL OR p_miesiac NOT BETWEEN 1 AND 12
    OR p_rok IS NULL OR p_rok NOT BETWEEN 2000 AND 2100 THEN
      RAISE_APPLICATION_ERROR(-20030, 'Nieprawidłowy miesiąc lub rok raportu.');
    END IF;

    l_pocz := TO_DATE(p_rok || '-' || LPAD(p_miesiac, 2, '0') || '-01', 'YYYY-MM-DD');
    l_kon  := LAST_DAY(l_pocz);

    l_mies := f_przychod_miesieczny(ADD_MONTHS(l_pocz, -1), l_pocz);   -- [poprzedni, bieżący]

    SELECT COUNT(*), NVL(SUM(repair_cost), 0)
      INTO l_szkody, l_koszt_sz
      FROM damages
     WHERE TRUNC(reported_date) BETWEEN l_pocz AND l_kon;

    SELECT COUNT(*) INTO l_nowe
      FROM bookings
     WHERE TRUNC(created_at) BETWEEN l_pocz AND l_kon;

    DBMS_OUTPUT.PUT_LINE(RPAD('=', 70, '='));
    DBMS_OUTPUT.PUT_LINE('RAPORT MIESIĘCZNY: ' || TO_CHAR(l_pocz, 'YYYY-MM'));
    DBMS_OUTPUT.PUT_LINE(RPAD('=', 70, '='));
    DBMS_OUTPUT.PUT_LINE('Przychód:              ' || kwota(l_mies(2).przychod)
      || '  (poprzedni miesiąc: ' || kwota(l_mies(1).przychod)
      || CASE WHEN l_mies(2).zmiana_proc IS NOT NULL
              THEN ', zmiana ' || CASE WHEN l_mies(2).zmiana_proc > 0 THEN '+' END
                   || TO_CHAR(l_mies(2).zmiana_proc, 'FM99990.0') || '%' END
      || ')');
    DBMS_OUTPUT.PUT_LINE('Rozpoczęte wypożyczenia: ' || l_mies(2).liczba_wypozyczen);
    DBMS_OUTPUT.PUT_LINE('Nowe rezerwacje:        ' || l_nowe);
    DBMS_OUTPUT.PUT_LINE('Zgłoszone szkody:       ' || l_szkody || ' (koszt napraw ' || kwota(l_koszt_sz) || ')');

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Top 3 modele:');
    l_ile := 0;
    FOR r IN (SELECT * FROM TABLE(pkg_analityka.f_ranking_modeli(l_pocz, l_kon, 3))) LOOP
      l_ile := l_ile + 1;
      DBMS_OUTPUT.PUT_LINE('  ' || r.pozycja || '. ' || RPAD(r.marka_model, 22)
        || r.liczba_wypozyczen || ' wyp., ' || r.dni_wynajmu || ' dni, ' || kwota(r.przychod));
    END LOOP;
    IF l_ile = 0 THEN DBMS_OUTPUT.PUT_LINE('  (brak wypożyczeń)'); END IF;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Top 3 klienci:');
    l_ile := 0;
    FOR r IN (SELECT * FROM TABLE(pkg_analityka.f_top_klienci(3, l_pocz, l_kon))) LOOP
      l_ile := l_ile + 1;
      DBMS_OUTPUT.PUT_LINE('  ' || r.pozycja || '. ' || RPAD(r.klient, 22)
        || kwota(r.wydano) || ' (' || r.poziom || ')');
    END LOOP;
    IF l_ile = 0 THEN DBMS_OUTPUT.PUT_LINE('  (brak płatności)'); END IF;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      p_loguj_blad('PKG_ANALITYKA.P_RAPORT_MIESIECZNY', l_kod, l_msg, l_bt);
      RAISE;
  END p_raport_miesieczny;

  -- P2: funkcje analityczne nad obiektami z PKG_FLOTA
  PROCEDURE p_porownaj_oddzialy (
    p_od  IN DATE,
    p_do  IN DATE
  ) IS
    l_kod  NUMBER;
    l_msg  VARCHAR2(4000);
    l_bt   VARCHAR2(4000);
  BEGIN
    sprawdz_okres(p_od, p_do);

    DBMS_OUTPUT.PUT_LINE('PORÓWNANIE ODDZIAŁÓW ' || TO_CHAR(p_od, 'YYYY-MM-DD')
                         || ' – ' || TO_CHAR(p_do, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 80, '-'));

    FOR r IN (
      SELECT RANK() OVER (ORDER BY saldo DESC)                   AS poz,
             oddzial, wypozyczen, saldo,
             ROUND(100 * RATIO_TO_REPORT(saldo) OVER (), 1)     AS udzial,
             saldo / NULLIF(MAX(saldo) OVER (), 0)              AS wzgl
        FROM (SELECT s.rap.oddzial           AS oddzial,
                     s.rap.liczba_wypozyczen AS wypozyczen,
                     s.rap.saldo()           AS saldo
                FROM (SELECT pkg_flota.f_raport_oddzialu(b.branch_id, p_od, p_do) AS rap
                        FROM branches b) s)
       ORDER BY poz, oddzial)
    LOOP
      DBMS_OUTPUT.PUT_LINE(
           r.poz || '. ' || RPAD(r.oddzial, 20)
        || LPAD(r.wypozyczen, 3) || ' wyp.  '
        || LPAD(kwota(r.saldo), 14) || '  '
        || LPAD(TO_CHAR(r.udzial, 'FM990.0'), 5) || '%  '
        || RPAD('#', GREATEST(1, ROUND(NVL(r.wzgl, 0) * 20)), '#'));
    END LOOP;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      p_loguj_blad('PKG_ANALITYKA.P_POROWNAJ_ODDZIALY', l_kod, l_msg, l_bt);
      RAISE;
  END p_porownaj_oddzialy;

  -- P3: JSON z zagnieżdżonymi tablicami (Oracle 12.2+)
  PROCEDURE p_raport_json (
    p_od    IN  DATE,
    p_do    IN  DATE,
    o_json  OUT CLOB
  ) IS
    l_kod  NUMBER;
    l_msg  VARCHAR2(4000);
    l_bt   VARCHAR2(4000);
  BEGIN
    sprawdz_okres(p_od, p_do);

    SELECT JSON_OBJECT(
             'okres' VALUE JSON_OBJECT('od' VALUE TO_CHAR(p_od, 'YYYY-MM-DD'),
                                       'do' VALUE TO_CHAR(p_do, 'YYYY-MM-DD')),
             'wygenerowano' VALUE TO_CHAR(SYSDATE, 'YYYY-MM-DD"T"HH24:MI:SS'),
             'top_modele' VALUE (
               SELECT JSON_ARRAYAGG(
                        JSON_OBJECT('pozycja'    VALUE r.pozycja,
                                    'model'      VALUE r.marka_model,
                                    'wypozyczen' VALUE r.liczba_wypozyczen,
                                    'przychod'   VALUE r.przychod)
                        ORDER BY r.pozycja RETURNING CLOB)
                 FROM TABLE(pkg_analityka.f_ranking_modeli(p_od, p_do, 5)) r) FORMAT JSON,
             'top_klienci' VALUE (
               SELECT JSON_ARRAYAGG(
                        JSON_OBJECT('pozycja' VALUE k.pozycja,
                                    'klient'  VALUE k.klient,
                                    'wydano'  VALUE k.wydano,
                                    'poziom'  VALUE k.poziom)
                        ORDER BY k.pozycja RETURNING CLOB)
                 FROM TABLE(pkg_analityka.f_top_klienci(5, p_od, p_do)) k) FORMAT JSON,
             'przychod_miesieczny' VALUE (
               SELECT JSON_ARRAYAGG(
                        JSON_OBJECT('miesiac'     VALUE m.etykieta,
                                    'przychod'    VALUE m.przychod,
                                    'zmiana_proc' VALUE m.zmiana_proc)
                        ORDER BY m.miesiac RETURNING CLOB)
                 FROM TABLE(pkg_analityka.f_przychod_miesieczny(p_od, p_do)) m) FORMAT JSON,
             'przychod_wg_oddzialow' VALUE (
               SELECT JSON_ARRAYAGG(
                        JSON_OBJECT('oddzial' VALUE o.etykieta, 'kwota' VALUE o.wartosc)
                        RETURNING CLOB)
                 FROM TABLE(pkg_analityka.f_rozklad('ODDZIAL', p_od, p_do)) o) FORMAT JSON
             RETURNING CLOB)
      INTO o_json
      FROM dual;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      p_loguj_blad('PKG_ANALITYKA.P_RAPORT_JSON', l_kod, l_msg, l_bt);
      RAISE;
  END p_raport_json;

  -- P4: kilka niezależnych pętli kursorowych
  PROCEDURE p_wykryj_anomalie (
    p_dni_postoju  IN  PLS_INTEGER DEFAULT 60,
    o_liczba       OUT PLS_INTEGER
  ) IS
    l_sekcja  PLS_INTEGER;
    l_kod     NUMBER;
    l_msg     VARCHAR2(4000);
    l_bt      VARCHAR2(4000);

    PROCEDURE naglowek (p_tytul IN VARCHAR2) IS
    BEGIN
      DBMS_OUTPUT.PUT_LINE('');
      DBMS_OUTPUT.PUT_LINE('[' || p_tytul || ']');
      l_sekcja := 0;
    END naglowek;

    PROCEDURE alert (p_tekst IN VARCHAR2) IS
    BEGIN
      DBMS_OUTPUT.PUT_LINE('  ! ' || p_tekst);
      l_sekcja := l_sekcja + 1;
      o_liczba := o_liczba + 1;
    END alert;

    PROCEDURE stopka IS
    BEGIN
      IF l_sekcja = 0 THEN DBMS_OUTPUT.PUT_LINE('  brak'); END IF;
    END stopka;
  BEGIN
    IF p_dni_postoju IS NULL OR p_dni_postoju < 1 THEN
      RAISE_APPLICATION_ERROR(-20030, 'Liczba dni postoju musi być >= 1.');
    END IF;

    o_liczba := 0;
    DBMS_OUTPUT.PUT_LINE('WYKRYWANIE ANOMALII – stan na ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI'));

    naglowek('1. Przeterminowane zwroty');
    FOR r IN (SELECT b.booking_id, v.license_plate, u.first_name || ' ' || u.last_name AS klient,
                     u.phone_number, TRUNC(SYSDATE) - TRUNC(b.planned_end_date) AS dni
                FROM bookings b
                JOIN vehicles v ON v.vehicle_id = b.vehicle_id
                JOIN users u    ON u.user_id    = b.customer_id
               WHERE b.booking_status = 'ACTIVE'
                 AND TRUNC(b.planned_end_date) < TRUNC(SYSDATE)
               ORDER BY dni DESC)
    LOOP
      alert('Rezerwacja #' || r.booking_id || ' (' || r.license_plate || '): ' || r.klient
            || ', tel. ' || r.phone_number || ' – ' || r.dni || ' dni po terminie');
    END LOOP;
    stopka;

    naglowek('2. Rezerwacje na najbliższe 7 dni bez wpłaconej kaucji');
    FOR r IN (SELECT b.booking_id, b.start_date, v.license_plate,
                     u.first_name || ' ' || u.last_name AS klient
                FROM bookings b
                JOIN vehicles v ON v.vehicle_id = b.vehicle_id
                JOIN users u    ON u.user_id    = b.customer_id
               WHERE b.booking_status = 'RESERVED'
                 AND TRUNC(b.start_date) BETWEEN TRUNC(SYSDATE) AND TRUNC(SYSDATE) + 7
                 AND NOT EXISTS (SELECT 1 FROM transactions t
                                  WHERE t.booking_id = b.booking_id
                                    AND t.transaction_type = 'DEPOSIT')
               ORDER BY b.start_date)
    LOOP
      alert('Rezerwacja #' || r.booking_id || ' od ' || TO_CHAR(r.start_date, 'YYYY-MM-DD')
            || ' (' || r.license_plate || '): ' || r.klient);
    END LOOP;
    stopka;

    naglowek('3. Klienci obciążeni za szkody');
    FOR r IN (SELECT u.first_name || ' ' || u.last_name AS klient,
                     COUNT(*) AS szkody, SUM(d.repair_cost) AS koszt
                FROM damages d
                JOIN bookings b ON b.booking_id = d.booking_id
                JOIN users u    ON u.user_id    = b.customer_id
               WHERE d.charged_to_customer = 'Y'
               GROUP BY u.user_id, u.first_name, u.last_name
               ORDER BY szkody DESC, koszt DESC)
    LOOP
      alert(r.klient || ': ' || r.szkody || ' szkód, łącznie ' || kwota(r.koszt));
    END LOOP;
    stopka;

    naglowek('4. Nierentowne auta (koszt serwisu > przychód)');
    FOR r IN (SELECT v.license_plate, m.make_name || ' ' || vt.model_name AS auto,
                     NVL(p.przychod, 0) AS przychod, s.koszt
                FROM vehicles v
                JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
                JOIN makes m          ON m.make_id          = vt.make_id
                JOIN (SELECT vehicle_id, SUM(cost) AS koszt
                        FROM maintenance GROUP BY vehicle_id) s
                  ON s.vehicle_id = v.vehicle_id
                LEFT JOIN (SELECT b.vehicle_id, SUM(t.amount) AS przychod
                             FROM transactions t
                             JOIN bookings b ON b.booking_id = t.booking_id
                            WHERE t.transaction_type IN ('PAYMENT', 'DAMAGE_FEE')
                            GROUP BY b.vehicle_id) p
                  ON p.vehicle_id = v.vehicle_id
               WHERE s.koszt > NVL(p.przychod, 0)
               ORDER BY s.koszt - NVL(p.przychod, 0) DESC)
    LOOP
      alert(r.license_plate || ' ' || r.auto || ': przychód ' || kwota(r.przychod)
            || ', serwis ' || kwota(r.koszt));
    END LOOP;
    stopka;

    naglowek('5. Dostępne auta bez wynajmu od ' || p_dni_postoju || '+ dni');
    FOR r IN (SELECT v.license_plate, m.make_name || ' ' || vt.model_name AS auto, br.branch_name,
                     MAX(NVL(b.actual_return_date, b.start_date)) AS ostatnio
                FROM vehicles v
                JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
                JOIN makes m          ON m.make_id          = vt.make_id
                JOIN branches br      ON br.branch_id       = v.branch_id
                LEFT JOIN bookings b  ON b.vehicle_id = v.vehicle_id
                                     AND b.booking_status IN ('ACTIVE', 'COMPLETED')
               WHERE v.vehicle_status = 'AVAILABLE'
               GROUP BY v.license_plate, m.make_name, vt.model_name, br.branch_name
              HAVING NVL(MAX(NVL(b.actual_return_date, b.start_date)), DATE '1900-01-01')
                     < TRUNC(SYSDATE) - p_dni_postoju
               ORDER BY ostatnio NULLS FIRST)
    LOOP
      alert(r.license_plate || ' ' || RPAD(r.auto, 18) || ' (' || r.branch_name || ') – '
            || CASE WHEN r.ostatnio IS NULL THEN 'nigdy nie wynajęte'
                    ELSE 'ostatnio ' || TO_CHAR(r.ostatnio, 'YYYY-MM-DD') END);
    END LOOP;
    stopka;

    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Łącznie alertów: ' || o_liczba);

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      p_loguj_blad('PKG_ANALITYKA.P_WYKRYJ_ANOMALIE', l_kod, l_msg, l_bt);
      RAISE;
  END p_wykryj_anomalie;

END pkg_analityka;
/
SHOW ERRORS
