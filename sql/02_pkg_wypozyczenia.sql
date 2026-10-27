/* =====================================================================
   PAKIET 1: PKG_WYPOZYCZENIA – rezerwacje, wydanie i zwrot pojazdu
   Wymaga: 01_schemat_i_dane.sql (tabele + dane)

   Zawartość skryptu:
     0. Tabela ERROR_LOG + procedura P_LOGUJ_BLAD (wspólne dla obu pakietów)
     1. Usunięcie starego pakietu i typów (skrypt można uruchamiać ponownie)
     2. Typy obiektowe i kolekcje SQL
     3. Specyfikacja pakietu
     4. Ciało pakietu

   Funkcje (5):
     F1 f_czy_dostepne             – czy auto jest wolne w terminie (1/0)
     F2 f_oblicz_koszt             – kalkulacja kosztu -> obiekt T_KOSZT
     F3 f_dostepne_auta            – lista wolnych aut -> kolekcja T_AUTO_DOSTEPNE_TAB
     F4 f_czy_klient_uprawniony    – wiek >= 21 i prawo jazdy >= 1 rok (1/0)
     F5 f_suma_wplat               – suma wpłat dla rezerwacji (wg typu lub netto)
   Procedury (5):
     P1 p_utworz_rezerwacje        – UC03
     P2 p_anuluj_rezerwacje        – UC04 (+ zwrot wpłaconej kaucji)
     P3 p_wydaj_auto               – UC06 (+ weryfikacja klienta, pobranie kaucji)
     P4 p_przyjmij_zwrot           – UC07 (+ rozliczenie, spóźnienie, szkody, kaucja)
     P5 p_drukuj_historie_klienta  – UC05 (kursor jawny OPEN/FETCH/CLOSE)

   Kody błędów (RAISE_APPLICATION_ERROR):
     -20001 auto niedostępne          -20006 nie znaleziono rekordu
     -20002 nieprawidłowe daty        -20007 nieprawidłowy przebieg
     -20003 zły kod rabatowy          -20008 błąd płatności
     -20004 klient nieuprawniony      -20009 nieprawidłowe dane szkody
     -20005 zły status rezerwacji
   ===================================================================== */


/* =====================================================================
   0. LOGOWANIE BŁĘDÓW (tworzone tylko, jeśli jeszcze nie istnieje)
   ===================================================================== */
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE error_log (
      log_id         NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      log_date       TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      db_user        VARCHAR2(128) DEFAULT USER NOT NULL,
      app_user       VARCHAR2(255),
      source_name    VARCHAR2(100),
      error_code     NUMBER,
      error_message  VARCHAR2(4000),
      backtrace      VARCHAR2(4000)
    )]';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;   -- -955 = tabela już istnieje
END;
/

-- Zapis błędu w osobnej (autonomicznej) transakcji:
-- log zostaje w bazie nawet wtedy, gdy główna operacja zostanie wycofana.
CREATE OR REPLACE PROCEDURE p_loguj_blad (
  p_zrodlo     IN VARCHAR2,
  p_kod        IN NUMBER,
  p_komunikat  IN VARCHAR2,
  p_backtrace  IN VARCHAR2 DEFAULT NULL
) IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  l_app_user  VARCHAR2(255);
BEGIN
  BEGIN
    l_app_user := SYS_CONTEXT('APEX$SESSION', 'APP_USER');  -- użytkownik APEX (poza APEX = NULL)
  EXCEPTION
    WHEN OTHERS THEN l_app_user := NULL;
  END;

  INSERT INTO error_log (app_user, source_name, error_code, error_message, backtrace)
  VALUES (l_app_user, p_zrodlo, p_kod, SUBSTR(p_komunikat, 1, 4000), SUBSTR(p_backtrace, 1, 4000));
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;   -- błąd logowania nie może przykryć właściwego błędu
END p_loguj_blad;
/
SHOW ERRORS


/* =====================================================================
   1. USUNIĘCIE STAREGO PAKIETU I TYPÓW (ponowne uruchomienie skryptu)
   ===================================================================== */
BEGIN
  FOR p IN (SELECT object_name FROM user_objects
             WHERE object_type = 'PACKAGE' AND object_name = 'PKG_WYPOZYCZENIA')
  LOOP
    EXECUTE IMMEDIATE 'DROP PACKAGE pkg_wypozyczenia';
  END LOOP;

  -- najpierw kolekcje, potem typy elementów
  FOR t IN (SELECT type_name FROM user_types
             WHERE type_name IN ('T_AUTO_DOSTEPNE_TAB','T_SZKODA_TAB',
                                 'T_AUTO_DOSTEPNE','T_SZKODA','T_KOSZT')
             ORDER BY CASE WHEN type_name LIKE '%TAB' THEN 0 ELSE 1 END)
  LOOP
    EXECUTE IMMEDIATE 'DROP TYPE ' || t.type_name || ' FORCE';
  END LOOP;
END;
/


/* =====================================================================
   2. TYPY OBIEKTOWE I KOLEKCJE
   ===================================================================== */

-- Wynik kalkulacji kosztu (obiekt z metodą)
CREATE OR REPLACE TYPE t_koszt AS OBJECT (
  liczba_dni          NUMBER,
  stawka_dzienna      NUMBER(8,2),
  kwota_bazowa        NUMBER(10,2),
  rabat_proc          NUMBER(5,2),
  kwota_rabatu        NUMBER(10,2),
  dni_spoznienia      NUMBER,
  doplata_spoznienie  NUMBER(10,2),
  suma                NUMBER(10,2),
  MEMBER FUNCTION opis RETURN VARCHAR2
);
/
SHOW ERRORS

CREATE OR REPLACE TYPE BODY t_koszt AS
  MEMBER FUNCTION opis RETURN VARCHAR2 IS
  BEGIN
    RETURN liczba_dni || ' dni x ' || TO_CHAR(stawka_dzienna, 'FM99990.00') || ' zł = '
        || TO_CHAR(kwota_bazowa, 'FM9999990.00') || ' zł'
        || CASE WHEN kwota_rabatu > 0 THEN
             ', rabat ' || rabat_proc || '% (-' || TO_CHAR(kwota_rabatu, 'FM9999990.00') || ' zł)'
           END
        || CASE WHEN dni_spoznienia > 0 THEN
             ', spóźnienie ' || dni_spoznienia || ' dni (+' || TO_CHAR(doplata_spoznienie, 'FM9999990.00') || ' zł)'
           END
        || '; RAZEM: ' || TO_CHAR(suma, 'FM9999990.00') || ' zł';
  END opis;
END;
/
SHOW ERRORS

-- Pojedyncze wolne auto + kolekcja (zwracana przez F3, używana w APEX przez TABLE())
CREATE OR REPLACE TYPE t_auto_dostepne AS OBJECT (
  vehicle_id        NUMBER,
  nr_rejestracyjny  VARCHAR2(10 CHAR),
  marka             VARCHAR2(50 CHAR),
  model_auta        VARCHAR2(50 CHAR),
  kategoria         VARCHAR2(10 CHAR),
  skrzynia          VARCHAR2(10 CHAR),
  paliwo            VARCHAR2(10 CHAR),
  oddzial           VARCHAR2(60 CHAR),
  stawka_dzienna    NUMBER(8,2),
  koszt_szacowany   NUMBER(10,2)
);
/
CREATE OR REPLACE TYPE t_auto_dostepne_tab AS TABLE OF t_auto_dostepne;
/

-- Szkoda zgłaszana przy zwrocie + kolekcja (parametr wejściowy P4)
CREATE OR REPLACE TYPE t_szkoda AS OBJECT (
  opis            VARCHAR2(400 CHAR),
  stopien         VARCHAR2(6 CHAR),     -- LOW / MEDIUM / HIGH
  koszt_naprawy   NUMBER(10,2),
  z_winy_klienta  CHAR(1)               -- Y / N
);
/
CREATE OR REPLACE TYPE t_szkoda_tab AS TABLE OF t_szkoda;
/


/* =====================================================================
   3. SPECYFIKACJA PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE pkg_wypozyczenia AS

  -- Stałe reguł biznesowych
  c_kaucja         CONSTANT NUMBER := 500;
  c_min_wiek       CONSTANT NUMBER := 21;
  c_min_staz_lat   CONSTANT NUMBER := 1;

  -- Wyjątki nazwane (można je łapać po nazwie: WHEN pkg_wypozyczenia.e_auto_niedostepne)
  e_auto_niedostepne      EXCEPTION;  PRAGMA EXCEPTION_INIT(e_auto_niedostepne,     -20001);
  e_zle_daty              EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zle_daty,             -20002);
  e_zly_kod_rabatowy      EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zly_kod_rabatowy,     -20003);
  e_klient_nieuprawniony  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_klient_nieuprawniony, -20004);
  e_zly_status            EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zly_status,           -20005);
  e_nie_znaleziono        EXCEPTION;  PRAGMA EXCEPTION_INIT(e_nie_znaleziono,       -20006);
  e_zly_przebieg          EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zly_przebieg,         -20007);
  e_platnosc              EXCEPTION;  PRAGMA EXCEPTION_INIT(e_platnosc,             -20008);
  e_zle_dane_szkody       EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zle_dane_szkody,      -20009);

  /* ---------------- FUNKCJE ---------------- */

  -- F1: 1 = auto wolne w terminie [p_od, p_do), 0 = zajęte / w serwisie / wycofane
  FUNCTION f_czy_dostepne (
    p_vehicle_id         IN vehicles.vehicle_id%TYPE,
    p_od                 IN DATE,
    p_do                 IN DATE,
    p_pomin_rezerwacje   IN bookings.booking_id%TYPE DEFAULT NULL
  ) RETURN NUMBER;

  -- F2: kalkulacja kosztu wynajmu (opcjonalnie z kodem rabatowym i datą faktycznego zwrotu)
  FUNCTION f_oblicz_koszt (
    p_vehicle_id     IN vehicles.vehicle_id%TYPE,
    p_od             IN DATE,
    p_do             IN DATE,
    p_kod_promocji   IN promotions.promo_code%TYPE DEFAULT NULL,
    p_data_zwrotu    IN DATE DEFAULT NULL
  ) RETURN t_koszt;

  -- F3: lista wolnych aut w terminie (do użycia w SQL: SELECT * FROM TABLE(...))
  FUNCTION f_dostepne_auta (
    p_od             IN DATE,
    p_do             IN DATE,
    p_oddzial_id     IN branches.branch_id%TYPE DEFAULT NULL,
    p_kategoria      IN vehicle_types.category%TYPE DEFAULT NULL,
    p_kod_promocji   IN promotions.promo_code%TYPE DEFAULT NULL
  ) RETURN t_auto_dostepne_tab;

  -- F4: 1 = klient spełnia wymagania (wiek i staż prawa jazdy) na dany dzień
  FUNCTION f_czy_klient_uprawniony (
    p_customer_id  IN customers.user_id%TYPE,
    p_na_dzien     IN DATE DEFAULT SYSDATE
  ) RETURN NUMBER;

  -- F5: suma transakcji rezerwacji danego typu; bez typu = saldo netto (zwroty na minus)
  FUNCTION f_suma_wplat (
    p_booking_id  IN bookings.booking_id%TYPE,
    p_typ         IN transactions.transaction_type%TYPE DEFAULT NULL
  ) RETURN NUMBER;

  /* ---------------- PROCEDURY ---------------- */

  -- P1 (UC03): nowa rezerwacja
  PROCEDURE p_utworz_rezerwacje (
    p_customer_id   IN  customers.user_id%TYPE,
    p_vehicle_id    IN  vehicles.vehicle_id%TYPE,
    p_employee_id   IN  employees.user_id%TYPE,
    p_od            IN  DATE,
    p_do            IN  DATE,
    p_kod_promocji  IN  promotions.promo_code%TYPE DEFAULT NULL,
    o_booking_id    OUT bookings.booking_id%TYPE
  );

  -- P2 (UC04): anulowanie rezerwacji (tylko RESERVED) + zwrot wpłaconej kaucji
  PROCEDURE p_anuluj_rezerwacje (
    p_booking_id  IN bookings.booking_id%TYPE
  );

  -- P3 (UC06): wydanie auta – weryfikacja klienta, pobranie kaucji, status ACTIVE/RENTED
  PROCEDURE p_wydaj_auto (
    p_booking_id   IN bookings.booking_id%TYPE,
    p_employee_id  IN employees.user_id%TYPE,
    p_metoda       IN transactions.payment_method%TYPE,
    p_karta_id     IN payment_details.payment_details_id%TYPE DEFAULT NULL
  );

  -- P4 (UC07): przyjęcie zwrotu – koszt, spóźnienie, szkody, kara, rozliczenie kaucji
  PROCEDURE p_przyjmij_zwrot (
    p_booking_id        IN  bookings.booking_id%TYPE,
    p_przebieg_koncowy  IN  vehicles.mileage%TYPE,
    p_metoda            IN  transactions.payment_method%TYPE,
    p_karta_id          IN  payment_details.payment_details_id%TYPE DEFAULT NULL,
    p_szkody            IN  t_szkoda_tab DEFAULT NULL,
    p_data_zwrotu       IN  DATE DEFAULT SYSDATE,
    o_koszt             OUT t_koszt
  );

  -- P5 (UC05): wydruk historii klienta (DBMS_OUTPUT)
  PROCEDURE p_drukuj_historie_klienta (
    p_customer_id  IN customers.user_id%TYPE
  );

END pkg_wypozyczenia;
/
SHOW ERRORS


/* =====================================================================
   4. CIAŁO PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE BODY pkg_wypozyczenia AS

  /* =================== ELEMENTY PRYWATNE =================== */

  -- Kontrola zakresu dat
  PROCEDURE sprawdz_daty (p_od IN DATE, p_do IN DATE) IS
  BEGIN
    IF p_od IS NULL OR p_do IS NULL OR TRUNC(p_do) <= TRUNC(p_od) THEN
      RAISE_APPLICATION_ERROR(-20002,
        'Data zakończenia musi być późniejsza niż data rozpoczęcia.');
    END IF;
  END sprawdz_daty;

  -- Stawka dzienna konkretnego auta
  FUNCTION stawka_auta (p_vehicle_id IN vehicles.vehicle_id%TYPE) RETURN NUMBER IS
    l_stawka  vehicle_types.daily_rate%TYPE;
  BEGIN
    SELECT vt.daily_rate
      INTO l_stawka
      FROM vehicles v
      JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
     WHERE v.vehicle_id = p_vehicle_id;
    RETURN l_stawka;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pojazdu o ID ' || p_vehicle_id || '.');
  END stawka_auta;

  -- Kod rabatowy -> ID i procent (kod musi obowiązywać w dniu rozpoczęcia wynajmu)
  PROCEDURE pobierz_promocje (
    p_kod   IN  VARCHAR2,
    p_data  IN  DATE,
    o_id    OUT promotions.promotion_id%TYPE,
    o_proc  OUT promotions.discount_percent%TYPE
  ) IS
  BEGIN
    SELECT promotion_id, discount_percent
      INTO o_id, o_proc
      FROM promotions
     WHERE UPPER(promo_code) = UPPER(TRIM(p_kod))
       AND TRUNC(p_data) BETWEEN valid_from AND valid_to;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20003,
        'Kod rabatowy "' || p_kod || '" nie istnieje lub nie obowiązuje w dniu '
        || TO_CHAR(p_data, 'YYYY-MM-DD') || '.');
  END pobierz_promocje;

  -- Rdzeń kalkulacji kosztu.
  -- Dni planowane: stawka z rabatem. Każdy dzień spóźnienia: pełna stawka (bez rabatu).
  -- Wcześniejszy zwrot nie obniża ceny (płaci się za zarezerwowany okres).
  FUNCTION oblicz (
    p_stawka  IN NUMBER,
    p_od      IN DATE,
    p_do      IN DATE,
    p_rabat   IN NUMBER,
    p_zwrot   IN DATE
  ) RETURN t_koszt IS
    l_dni       NUMBER := GREATEST(1, TRUNC(p_do) - TRUNC(p_od));
    l_bazowa    NUMBER;
    l_rabat     NUMBER;
    l_spoz      NUMBER := 0;
    l_doplata   NUMBER := 0;
  BEGIN
    l_bazowa := ROUND(l_dni * p_stawka, 2);
    l_rabat  := ROUND(l_bazowa * NVL(p_rabat, 0) / 100, 2);

    IF p_zwrot IS NOT NULL AND TRUNC(p_zwrot) > TRUNC(p_do) THEN
      l_spoz    := TRUNC(p_zwrot) - TRUNC(p_do);
      l_doplata := ROUND(l_spoz * p_stawka, 2);
    END IF;

    RETURN t_koszt(l_dni, p_stawka, l_bazowa, NVL(p_rabat, 0), l_rabat,
                   l_spoz, l_doplata, l_bazowa - l_rabat + l_doplata);
  END oblicz;

  -- Pobranie rezerwacji z blokadą wiersza (chroni przed równoczesną obsługą)
  FUNCTION pobierz_rezerwacje (p_booking_id IN bookings.booking_id%TYPE)
    RETURN bookings%ROWTYPE
  IS
    l_b  bookings%ROWTYPE;
  BEGIN
    SELECT * INTO l_b FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
    RETURN l_b;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono rezerwacji nr ' || p_booking_id || '.');
  END pobierz_rezerwacje;

  -- Walidacja metody płatności i karty klienta
  PROCEDURE sprawdz_platnosc (
    p_customer_id  IN customers.user_id%TYPE,
    p_metoda       IN VARCHAR2,
    p_karta_id     IN NUMBER
  ) IS
    l_ile  NUMBER;
  BEGIN
    IF p_metoda IS NULL OR p_metoda NOT IN ('CARD', 'CASH', 'TRANSFER') THEN
      RAISE_APPLICATION_ERROR(-20008,
        'Nieznana metoda płatności: ' || NVL(p_metoda, '(brak)') || '. Dozwolone: CARD, CASH, TRANSFER.');
    END IF;

    IF p_metoda = 'CARD' THEN
      IF p_karta_id IS NULL THEN
        RAISE_APPLICATION_ERROR(-20008, 'Przy płatności kartą należy wskazać kartę klienta.');
      END IF;

      SELECT COUNT(*)
        INTO l_ile
        FROM payment_details
       WHERE payment_details_id = p_karta_id
         AND customer_id        = p_customer_id
         AND expiry_date       >= TRUNC(SYSDATE);

      IF l_ile = 0 THEN
        RAISE_APPLICATION_ERROR(-20008,
          'Karta ID ' || p_karta_id || ' nie należy do klienta lub straciła ważność.');
      END IF;
    END IF;
  END sprawdz_platnosc;

  -- Zapis transakcji (kwoty <= 0 są pomijane)
  PROCEDURE dodaj_transakcje (
    p_booking_id  IN NUMBER,
    p_karta_id    IN NUMBER,
    p_kwota       IN NUMBER,
    p_metoda      IN VARCHAR2,
    p_typ         IN VARCHAR2
  ) IS
  BEGIN
    IF p_kwota > 0 THEN
      INSERT INTO transactions (booking_id, payment_details_id, amount,
                                transaction_date, payment_method, transaction_type)
      VALUES (p_booking_id,
              CASE WHEN p_metoda = 'CARD' THEN p_karta_id END,
              ROUND(p_kwota, 2), SYSDATE, p_metoda, p_typ);
    END IF;
  END dodaj_transakcje;


  /* =================== FUNKCJE PUBLICZNE =================== */

  -- F1
  FUNCTION f_czy_dostepne (
    p_vehicle_id         IN vehicles.vehicle_id%TYPE,
    p_od                 IN DATE,
    p_do                 IN DATE,
    p_pomin_rezerwacje   IN bookings.booking_id%TYPE DEFAULT NULL
  ) RETURN NUMBER IS
    l_status   vehicles.vehicle_status%TYPE;
    l_kolizje  NUMBER;
  BEGIN
    sprawdz_daty(p_od, p_do);

    BEGIN
      SELECT vehicle_status INTO l_status FROM vehicles WHERE vehicle_id = p_vehicle_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pojazdu o ID ' || p_vehicle_id || '.');
    END;

    IF l_status IN ('MAINTENANCE', 'RETIRED') THEN
      RETURN 0;
    END IF;

    -- Kolizja terminów: [start, koniec) nachodzi na [p_od, p_do).
    -- Aktywne wypożyczenie po terminie blokuje auto co najmniej do jutra.
    SELECT COUNT(*)
      INTO l_kolizje
      FROM bookings b
     WHERE b.vehicle_id = p_vehicle_id
       AND b.booking_status IN ('RESERVED', 'ACTIVE')
       AND (p_pomin_rezerwacje IS NULL OR b.booking_id <> p_pomin_rezerwacje)
       AND TRUNC(b.start_date) < TRUNC(p_do)
       AND TRUNC(p_od) < CASE
                           WHEN b.booking_status = 'ACTIVE'
                             THEN GREATEST(TRUNC(b.planned_end_date), TRUNC(SYSDATE) + 1)
                           ELSE TRUNC(b.planned_end_date)
                         END;

    RETURN CASE WHEN l_kolizje = 0 THEN 1 ELSE 0 END;
  END f_czy_dostepne;

  -- F2
  FUNCTION f_oblicz_koszt (
    p_vehicle_id     IN vehicles.vehicle_id%TYPE,
    p_od             IN DATE,
    p_do             IN DATE,
    p_kod_promocji   IN promotions.promo_code%TYPE DEFAULT NULL,
    p_data_zwrotu    IN DATE DEFAULT NULL
  ) RETURN t_koszt IS
    l_promo_id  promotions.promotion_id%TYPE;
    l_rabat     promotions.discount_percent%TYPE := 0;
  BEGIN
    sprawdz_daty(p_od, p_do);

    IF p_kod_promocji IS NOT NULL THEN
      pobierz_promocje(p_kod_promocji, p_od, l_promo_id, l_rabat);
    END IF;

    RETURN oblicz(stawka_auta(p_vehicle_id), p_od, p_do, l_rabat, p_data_zwrotu);
  END f_oblicz_koszt;

  -- F3: kursor z parametrami + BULK COLLECT do kolekcji PL/SQL + budowa kolekcji SQL
  FUNCTION f_dostepne_auta (
    p_od             IN DATE,
    p_do             IN DATE,
    p_oddzial_id     IN branches.branch_id%TYPE DEFAULT NULL,
    p_kategoria      IN vehicle_types.category%TYPE DEFAULT NULL,
    p_kod_promocji   IN promotions.promo_code%TYPE DEFAULT NULL
  ) RETURN t_auto_dostepne_tab IS

    CURSOR c_auta (cp_oddzial NUMBER, cp_kategoria VARCHAR2) IS
      SELECT v.vehicle_id, v.license_plate, m.make_name, vt.model_name,
             vt.category, vt.transmission, vt.fuel_type, b.branch_name, vt.daily_rate
        FROM vehicles v
        JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
        JOIN makes m          ON m.make_id          = vt.make_id
        JOIN branches b       ON b.branch_id        = v.branch_id
       WHERE v.vehicle_status IN ('AVAILABLE', 'RENTED')
         AND (cp_oddzial   IS NULL OR v.branch_id = cp_oddzial)
         AND (cp_kategoria IS NULL OR vt.category = cp_kategoria)
       ORDER BY vt.daily_rate, v.license_plate;

    TYPE t_kandydaci IS TABLE OF c_auta%ROWTYPE;      -- kolekcja PL/SQL rekordów kursora

    l_kandydaci  t_kandydaci;
    l_wynik      t_auto_dostepne_tab := t_auto_dostepne_tab();
    l_koszt      t_koszt;
    l_promo_id   promotions.promotion_id%TYPE;
    l_rabat      promotions.discount_percent%TYPE := 0;
  BEGIN
    sprawdz_daty(p_od, p_do);

    IF p_kod_promocji IS NOT NULL THEN
      pobierz_promocje(p_kod_promocji, p_od, l_promo_id, l_rabat);
    END IF;

    OPEN c_auta(p_oddzial_id, UPPER(p_kategoria));
    FETCH c_auta BULK COLLECT INTO l_kandydaci;
    CLOSE c_auta;

    FOR i IN 1 .. l_kandydaci.COUNT LOOP
      IF f_czy_dostepne(l_kandydaci(i).vehicle_id, p_od, p_do) = 1 THEN
        l_koszt := oblicz(l_kandydaci(i).daily_rate, p_od, p_do, l_rabat, NULL);

        l_wynik.EXTEND;
        l_wynik(l_wynik.LAST) := t_auto_dostepne(
          l_kandydaci(i).vehicle_id,
          l_kandydaci(i).license_plate,
          l_kandydaci(i).make_name,
          l_kandydaci(i).model_name,
          l_kandydaci(i).category,
          l_kandydaci(i).transmission,
          l_kandydaci(i).fuel_type,
          l_kandydaci(i).branch_name,
          l_kandydaci(i).daily_rate,
          l_koszt.suma);
      END IF;
    END LOOP;

    RETURN l_wynik;
  END f_dostepne_auta;

  -- F4
  FUNCTION f_czy_klient_uprawniony (
    p_customer_id  IN customers.user_id%TYPE,
    p_na_dzien     IN DATE DEFAULT SYSDATE
  ) RETURN NUMBER IS
    l_urodzony     users.date_of_birth%TYPE;
    l_prawo_jazdy  customers.license_issue_date%TYPE;
  BEGIN
    SELECT u.date_of_birth, c.license_issue_date
      INTO l_urodzony, l_prawo_jazdy
      FROM customers c
      JOIN users u ON u.user_id = c.user_id
     WHERE c.user_id = p_customer_id;

    IF MONTHS_BETWEEN(TRUNC(p_na_dzien), l_urodzony)    / 12 < c_min_wiek
    OR MONTHS_BETWEEN(TRUNC(p_na_dzien), l_prawo_jazdy) / 12 < c_min_staz_lat
    THEN
      RETURN 0;
    END IF;
    RETURN 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono klienta o ID ' || p_customer_id || '.');
  END f_czy_klient_uprawniony;

  -- F5
  FUNCTION f_suma_wplat (
    p_booking_id  IN bookings.booking_id%TYPE,
    p_typ         IN transactions.transaction_type%TYPE DEFAULT NULL
  ) RETURN NUMBER IS
    l_suma  NUMBER;
  BEGIN
    SELECT NVL(SUM(CASE
                     WHEN p_typ IS NOT NULL THEN amount
                     WHEN transaction_type = 'REFUND' THEN -amount
                     ELSE amount
                   END), 0)
      INTO l_suma
      FROM transactions
     WHERE booking_id = p_booking_id
       AND (p_typ IS NULL OR transaction_type = p_typ);
    RETURN l_suma;
  END f_suma_wplat;


  /* =================== PROCEDURY PUBLICZNE =================== */

  -- P1
  PROCEDURE p_utworz_rezerwacje (
    p_customer_id   IN  customers.user_id%TYPE,
    p_vehicle_id    IN  vehicles.vehicle_id%TYPE,
    p_employee_id   IN  employees.user_id%TYPE,
    p_od            IN  DATE,
    p_do            IN  DATE,
    p_kod_promocji  IN  promotions.promo_code%TYPE DEFAULT NULL,
    o_booking_id    OUT bookings.booking_id%TYPE
  ) IS
    l_vehicle_id  vehicles.vehicle_id%TYPE;
    l_ile         NUMBER;
    l_promo_id    promotions.promotion_id%TYPE;
    l_rabat       promotions.discount_percent%TYPE;
    l_kod         NUMBER;
    l_msg         VARCHAR2(4000);
    l_bt          VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_rezerwacja;

    sprawdz_daty(p_od, p_do);
    IF TRUNC(p_od) < TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(-20002, 'Nie można utworzyć rezerwacji z datą w przeszłości.');
    END IF;

    SELECT COUNT(*) INTO l_ile FROM employees WHERE user_id = p_employee_id;
    IF l_ile = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pracownika o ID ' || p_employee_id || '.');
    END IF;

    -- blokada wiersza auta: dwie osoby nie zarezerwują go jednocześnie
    BEGIN
      SELECT vehicle_id INTO l_vehicle_id
        FROM vehicles WHERE vehicle_id = p_vehicle_id
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pojazdu o ID ' || p_vehicle_id || '.');
    END;

    IF f_czy_klient_uprawniony(p_customer_id, p_od) = 0 THEN
      RAISE_APPLICATION_ERROR(-20004,
        'Klient nie spełnia wymagań: min. ' || c_min_wiek || ' lat i prawo jazdy od min. '
        || c_min_staz_lat || ' roku.');
    END IF;

    IF f_czy_dostepne(p_vehicle_id, p_od, p_do) = 0 THEN
      RAISE_APPLICATION_ERROR(-20001,
        'Pojazd ID ' || p_vehicle_id || ' jest niedostępny w terminie '
        || TO_CHAR(p_od, 'YYYY-MM-DD') || ' – ' || TO_CHAR(p_do, 'YYYY-MM-DD') || '.');
    END IF;

    IF p_kod_promocji IS NOT NULL THEN
      pobierz_promocje(p_kod_promocji, p_od, l_promo_id, l_rabat);
    END IF;

    INSERT INTO bookings (customer_id, vehicle_id, employee_id, promotion_id,
                          booking_status, start_date, planned_end_date)
    VALUES (p_customer_id, p_vehicle_id, p_employee_id, l_promo_id,
            'RESERVED', TRUNC(p_od), TRUNC(p_do))
    RETURNING booking_id INTO o_booking_id;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_rezerwacja;
      p_loguj_blad('PKG_WYPOZYCZENIA.P_UTWORZ_REZERWACJE', l_kod, l_msg, l_bt);
      RAISE;
  END p_utworz_rezerwacje;

  -- P2
  PROCEDURE p_anuluj_rezerwacje (
    p_booking_id  IN bookings.booking_id%TYPE
  ) IS
    l_b        bookings%ROWTYPE;
    l_wplacono NUMBER;
    l_metoda   transactions.payment_method%TYPE;
    l_karta    transactions.payment_details_id%TYPE;
    l_kod      NUMBER;
    l_msg      VARCHAR2(4000);
    l_bt       VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_anulowanie;

    l_b := pobierz_rezerwacje(p_booking_id);

    IF l_b.booking_status <> 'RESERVED' THEN
      RAISE_APPLICATION_ERROR(-20005,
        'Można anulować tylko rezerwację o statusie RESERVED (rezerwacja nr '
        || p_booking_id || ' ma status ' || l_b.booking_status || ').');
    END IF;

    UPDATE bookings SET booking_status = 'CANCELLED' WHERE booking_id = p_booking_id;

    -- zwrot wpłaconej zaliczki/kaucji tą samą metodą, którą klient zapłacił
    l_wplacono := f_suma_wplat(p_booking_id);
    IF l_wplacono > 0 THEN
      SELECT payment_method, payment_details_id
        INTO l_metoda, l_karta
        FROM (SELECT payment_method, payment_details_id
                FROM transactions
               WHERE booking_id = p_booking_id
                 AND transaction_type = 'DEPOSIT'
               ORDER BY transaction_date DESC, transaction_id DESC)
       WHERE ROWNUM = 1;

      dodaj_transakcje(p_booking_id, l_karta, l_wplacono, l_metoda, 'REFUND');
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_anulowanie;
      p_loguj_blad('PKG_WYPOZYCZENIA.P_ANULUJ_REZERWACJE', l_kod, l_msg, l_bt);
      RAISE;
  END p_anuluj_rezerwacje;

  -- P3
  PROCEDURE p_wydaj_auto (
    p_booking_id   IN bookings.booking_id%TYPE,
    p_employee_id  IN employees.user_id%TYPE,
    p_metoda       IN transactions.payment_method%TYPE,
    p_karta_id     IN payment_details.payment_details_id%TYPE DEFAULT NULL
  ) IS
    l_b          bookings%ROWTYPE;
    l_status     vehicles.vehicle_status%TYPE;
    l_przebieg   vehicles.mileage%TYPE;
    l_ile        NUMBER;
    l_do_zaplaty NUMBER;
    l_kod        NUMBER;
    l_msg        VARCHAR2(4000);
    l_bt         VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_wydanie;

    l_b := pobierz_rezerwacje(p_booking_id);

    IF l_b.booking_status <> 'RESERVED' THEN
      RAISE_APPLICATION_ERROR(-20005,
        'Wydać można tylko auto z rezerwacji o statusie RESERVED (rezerwacja nr '
        || p_booking_id || ' ma status ' || l_b.booking_status || ').');
    END IF;

    IF TRUNC(SYSDATE) < TRUNC(l_b.start_date) THEN
      RAISE_APPLICATION_ERROR(-20002,
        'Rezerwacja zaczyna się ' || TO_CHAR(l_b.start_date, 'YYYY-MM-DD')
        || ' – auta nie można wydać wcześniej.');
    ELSIF TRUNC(SYSDATE) >= TRUNC(l_b.planned_end_date) THEN
      RAISE_APPLICATION_ERROR(-20002,
        'Termin rezerwacji minął (' || TO_CHAR(l_b.planned_end_date, 'YYYY-MM-DD') || ').');
    END IF;

    SELECT COUNT(*) INTO l_ile FROM employees WHERE user_id = p_employee_id;
    IF l_ile = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono pracownika o ID ' || p_employee_id || '.');
    END IF;

    IF f_czy_klient_uprawniony(l_b.customer_id) = 0 THEN
      RAISE_APPLICATION_ERROR(-20004,
        'Klient nie spełnia wymagań: min. ' || c_min_wiek || ' lat i prawo jazdy od min. '
        || c_min_staz_lat || ' roku.');
    END IF;

    SELECT vehicle_status, mileage
      INTO l_status, l_przebieg
      FROM vehicles
     WHERE vehicle_id = l_b.vehicle_id
       FOR UPDATE;

    IF l_status <> 'AVAILABLE' THEN
      RAISE_APPLICATION_ERROR(-20001,
        'Pojazd ID ' || l_b.vehicle_id || ' nie może zostać wydany (status: ' || l_status || ').');
    END IF;

    sprawdz_platnosc(l_b.customer_id, p_metoda, p_karta_id);

    -- kaucja: dopłata do pełnej kwoty (część mogła zostać wpłacona przy rezerwacji)
    l_do_zaplaty := c_kaucja - f_suma_wplat(p_booking_id, 'DEPOSIT');
    dodaj_transakcje(p_booking_id, p_karta_id, l_do_zaplaty, p_metoda, 'DEPOSIT');

    UPDATE bookings
       SET booking_status = 'ACTIVE',
           start_mileage  = l_przebieg,
           employee_id    = p_employee_id
     WHERE booking_id = p_booking_id;

    UPDATE vehicles SET vehicle_status = 'RENTED' WHERE vehicle_id = l_b.vehicle_id;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_wydanie;
      p_loguj_blad('PKG_WYPOZYCZENIA.P_WYDAJ_AUTO', l_kod, l_msg, l_bt);
      RAISE;
  END p_wydaj_auto;

  -- P4
  PROCEDURE p_przyjmij_zwrot (
    p_booking_id        IN  bookings.booking_id%TYPE,
    p_przebieg_koncowy  IN  vehicles.mileage%TYPE,
    p_metoda            IN  transactions.payment_method%TYPE,
    p_karta_id          IN  payment_details.payment_details_id%TYPE DEFAULT NULL,
    p_szkody            IN  t_szkoda_tab DEFAULT NULL,
    p_data_zwrotu       IN  DATE DEFAULT SYSDATE,
    o_koszt             OUT t_koszt
  ) IS
    l_b          bookings%ROWTYPE;
    l_rabat      promotions.discount_percent%TYPE := 0;
    l_kara       NUMBER := 0;
    l_kaucja     NUMBER;
    l_potracenie NUMBER;
    l_powazna    BOOLEAN := FALSE;
    l_nowy_status vehicles.vehicle_status%TYPE;
    l_suma       NUMBER;
    l_typ_serw   maintenance_types.maintenance_type_id%TYPE;
    l_kod        NUMBER;
    l_msg        VARCHAR2(4000);
    l_bt         VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_zwrot;

    l_b := pobierz_rezerwacje(p_booking_id);

    IF l_b.booking_status <> 'ACTIVE' THEN
      RAISE_APPLICATION_ERROR(-20005,
        'Zwrot można przyjąć tylko dla aktywnego wypożyczenia (rezerwacja nr '
        || p_booking_id || ' ma status ' || l_b.booking_status || ').');
    END IF;

    IF p_data_zwrotu IS NULL OR TRUNC(p_data_zwrotu) < TRUNC(l_b.start_date) THEN
      RAISE_APPLICATION_ERROR(-20002, 'Data zwrotu nie może być wcześniejsza niż data wydania.');
    END IF;

    IF p_przebieg_koncowy IS NULL OR p_przebieg_koncowy < l_b.start_mileage THEN
      RAISE_APPLICATION_ERROR(-20007,
        'Przebieg końcowy (' || NVL(TO_CHAR(p_przebieg_koncowy), 'brak')
        || ' km) nie może być mniejszy niż przy wydaniu (' || l_b.start_mileage || ' km).');
    END IF;

    sprawdz_platnosc(l_b.customer_id, p_metoda, p_karta_id);

    -- 1) koszt wynajmu (rabat z rezerwacji, spóźnienie po pełnej stawce)
    IF l_b.promotion_id IS NOT NULL THEN
      SELECT discount_percent INTO l_rabat
        FROM promotions WHERE promotion_id = l_b.promotion_id;
    END IF;

    o_koszt := oblicz(stawka_auta(l_b.vehicle_id), l_b.start_date, l_b.planned_end_date,
                      l_rabat, p_data_zwrotu);

    l_suma := o_koszt.suma;
    dodaj_transakcje(p_booking_id, p_karta_id, l_suma, p_metoda, 'PAYMENT');

    -- 2) szkody (kolekcja obiektów T_SZKODA)
    IF p_szkody IS NOT NULL THEN
      FOR i IN 1 .. p_szkody.COUNT LOOP
        IF p_szkody(i) IS NULL
        OR p_szkody(i).opis IS NULL
        OR NVL(p_szkody(i).stopien, 'X') NOT IN ('LOW', 'MEDIUM', 'HIGH')
        OR NVL(p_szkody(i).z_winy_klienta, 'N') NOT IN ('Y', 'N')
        OR NVL(p_szkody(i).koszt_naprawy, 0) < 0
        THEN
          RAISE_APPLICATION_ERROR(-20009,
            'Nieprawidłowe dane szkody nr ' || i
            || ' (wymagany opis, stopień LOW/MEDIUM/HIGH, koszt >= 0, wina Y/N).');
        END IF;

        INSERT INTO damages (booking_id, description, severity, repair_cost,
                             charged_to_customer, reported_date)
        VALUES (p_booking_id, p_szkody(i).opis, p_szkody(i).stopien,
                p_szkody(i).koszt_naprawy, NVL(p_szkody(i).z_winy_klienta, 'N'),
                TRUNC(p_data_zwrotu));

        IF NVL(p_szkody(i).z_winy_klienta, 'N') = 'Y' THEN
          l_kara := l_kara + NVL(p_szkody(i).koszt_naprawy, 0);
        END IF;

        IF p_szkody(i).stopien = 'HIGH' THEN
          l_powazna := TRUE;
        END IF;
      END LOOP;
    END IF;

    -- 3) kara za szkody: najpierw z kaucji, nadwyżka jako DAMAGE_FEE, reszta kaucji jako REFUND
    l_kaucja     := f_suma_wplat(p_booking_id, 'DEPOSIT');
    l_potracenie := LEAST(l_kara, l_kaucja);

    dodaj_transakcje(p_booking_id, p_karta_id, l_kara - l_kaucja,       p_metoda, 'DAMAGE_FEE');
    dodaj_transakcje(p_booking_id, p_karta_id, l_kaucja - l_potracenie, p_metoda, 'REFUND');

    -- 4) zamknięcie rezerwacji i aktualizacja pojazdu
    UPDATE bookings
       SET booking_status     = 'COMPLETED',
           actual_return_date = p_data_zwrotu,
           end_mileage        = p_przebieg_koncowy,
           total_cost         = l_suma
     WHERE booking_id = p_booking_id;

    -- (BOOLEAN nie może trafić do SQL, więc status wyliczamy w PL/SQL)
    IF l_powazna THEN
      l_nowy_status := 'MAINTENANCE';
    ELSE
      l_nowy_status := 'AVAILABLE';
    END IF;

    UPDATE vehicles
       SET mileage        = p_przebieg_koncowy,
           vehicle_status = l_nowy_status
     WHERE vehicle_id = l_b.vehicle_id;

    -- 5) poważna szkoda -> automatyczne zlecenie naprawy
    IF l_powazna THEN
      BEGIN
        SELECT maintenance_type_id INTO l_typ_serw
          FROM maintenance_types WHERE type_name = 'Naprawa blacharska';
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20006, 'Brak typu serwisu "Naprawa blacharska" w słowniku.');
      END;

      INSERT INTO maintenance (vehicle_id, maintenance_type_id, employee_id, start_date,
                               mileage_at_service, description)
      VALUES (l_b.vehicle_id, l_typ_serw, l_b.employee_id, TRUNC(p_data_zwrotu),
              p_przebieg_koncowy,
              'Automatycznie: poważna szkoda przy zwrocie (rezerwacja nr ' || p_booking_id || ')');
    END IF;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_zwrot;
      p_loguj_blad('PKG_WYPOZYCZENIA.P_PRZYJMIJ_ZWROT', l_kod, l_msg, l_bt);
      RAISE;
  END p_przyjmij_zwrot;

  -- P5: kursor jawny z parametrem (OPEN / FETCH / CLOSE, %ROWTYPE, %NOTFOUND, %ROWCOUNT)
  PROCEDURE p_drukuj_historie_klienta (
    p_customer_id  IN customers.user_id%TYPE
  ) IS
    CURSOR c_historia (cp_klient NUMBER) IS
      SELECT b.booking_id, b.booking_status, b.start_date, b.planned_end_date,
             v.license_plate, m.make_name || ' ' || vt.model_name AS auto, b.total_cost
        FROM bookings b
        JOIN vehicles v       ON v.vehicle_id       = b.vehicle_id
        JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
        JOIN makes m          ON m.make_id          = vt.make_id
       WHERE b.customer_id = cp_klient
       ORDER BY b.start_date;

    r_hist     c_historia%ROWTYPE;
    l_klient   VARCHAR2(200);
    l_ile      NUMBER;
    l_zaplacil NUMBER;
    l_kod      NUMBER;
    l_msg      VARCHAR2(4000);
    l_bt       VARCHAR2(4000);
  BEGIN
    BEGIN
      SELECT u.first_name || ' ' || u.last_name
        INTO l_klient
        FROM customers c JOIN users u ON u.user_id = c.user_id
       WHERE c.user_id = p_customer_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono klienta o ID ' || p_customer_id || '.');
    END;

    DBMS_OUTPUT.PUT_LINE('Historia klienta: ' || l_klient || ' (ID ' || p_customer_id || ')');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 90, '-'));

    OPEN c_historia(p_customer_id);
    LOOP
      FETCH c_historia INTO r_hist;
      EXIT WHEN c_historia%NOTFOUND;

      DBMS_OUTPUT.PUT_LINE(
           RPAD('#' || r_hist.booking_id, 6)
        || RPAD(r_hist.booking_status, 11)
        || TO_CHAR(r_hist.start_date, 'YYYY-MM-DD') || ' -> '
        || TO_CHAR(r_hist.planned_end_date, 'YYYY-MM-DD') || '  '
        || RPAD(r_hist.auto, 20) || RPAD(r_hist.license_plate, 10)
        || CASE WHEN r_hist.total_cost IS NULL THEN '-'
                ELSE TO_CHAR(r_hist.total_cost, 'FM9999990.00') || ' zł' END);
    END LOOP;
    l_ile := c_historia%ROWCOUNT;
    CLOSE c_historia;

    IF l_ile = 0 THEN
      DBMS_OUTPUT.PUT_LINE('(brak wypożyczeń)');
    END IF;

    SELECT NVL(SUM(CASE WHEN t.transaction_type = 'REFUND' THEN -t.amount ELSE t.amount END), 0)
      INTO l_zaplacil
      FROM transactions t
      JOIN bookings b ON b.booking_id = t.booking_id
     WHERE b.customer_id = p_customer_id;

    DBMS_OUTPUT.PUT_LINE(RPAD('-', 90, '-'));
    DBMS_OUTPUT.PUT_LINE('Rezerwacji: ' || l_ile || ', wpłaty netto: '
                         || TO_CHAR(l_zaplacil, 'FM9999990.00') || ' zł');

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      IF c_historia%ISOPEN THEN CLOSE c_historia; END IF;
      p_loguj_blad('PKG_WYPOZYCZENIA.P_DRUKUJ_HISTORIE_KLIENTA', l_kod, l_msg, l_bt);
      RAISE;
  END p_drukuj_historie_klienta;

END pkg_wypozyczenia;
/
SHOW ERRORS
