/* =====================================================================
   PAKIET 3: PKG_KLIENCI – konta, logowanie, karty, lojalność, RODO
   Wymaga: 01_schemat_i_dane.sql, 02_pkg_wypozyczenia.sql (ERROR_LOG, P_LOGUJ_BLAD)

   Zawartość skryptu:
     0. Tabela LOGIN_LOG (historia logowań, blokada konta)
     1. Usunięcie starego pakietu i typów
     2. Typy obiektowe i kolekcje
     3. Specyfikacja pakietu
     4. Ciało pakietu
     5. Hasła demonstracyjne dla danych przykładowych (Haslo123!)

   Funkcje (7):
     F1 f_zaloguj                – logowanie do APEX (własny schemat uwierzytelniania)
     F2 f_rola                   – rola użytkownika: ADMIN / MANAGER / CLERK / CUSTOMER
     F3 f_id_uzytkownika         – ID użytkownika po e-mailu (dla elementu aplikacji APEX)
     F4 f_poziom_lojalnosci      – STANDARD / SREBRNY / ZLOTY / PLATYNOWY
     F5 f_rabat_lojalnosciowy    – rabat % wynikający z poziomu
     F6 f_profil_klienta         – profil klienta -> obiekt T_PROFIL_KLIENTA
     F7 f_karty_wygasajace       – karty wygasające / wygasłe -> kolekcja T_KARTA_TAB
   Procedury (6):
     P1 p_zarejestruj_klienta    – rejestracja (USERS + CUSTOMERS w jednej transakcji)
     P2 p_ustaw_haslo            – nadanie hasła (np. reset przez administratora)
     P3 p_zmien_haslo            – zmiana hasła przez użytkownika
     P4 p_dodaj_karte            – walidacja algorytmem Luhna, wykrycie typu karty
     P5 p_usun_karte             – ORA-02292 zamieniony na czytelny komunikat
     P6 p_anonimizuj_klienta     – "prawo do bycia zapomnianym" (kursor FOR UPDATE)

   Kody błędów:
     -20006 nie znaleziono          -20023 konto zablokowane
     -20020 nieprawidłowe dane      -20024 błąd karty
     -20021 e-mail / prawo jazdy zajęte  -20025 klient ma aktywne rezerwacje
     -20022 hasło (słabe / błędne)

   Hasła: sól + SHA-256 (STANDARD_HASH), format "S1$<sól>$<hash>".
   Pełny numer karty NIGDY nie jest zapisywany – tylko typ i 4 ostatnie cyfry.
   ===================================================================== */


/* =====================================================================
   0. LOGIN_LOG
   ===================================================================== */
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE login_log (
      log_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      email       VARCHAR2(254 CHAR) NOT NULL,
      login_time  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
      success     CHAR(1) NOT NULL,
      ip_address  VARCHAR2(45),
      CONSTRAINT ck_login_success CHECK (success IN ('Y','N'))
    )]';
  EXECUTE IMMEDIATE 'CREATE INDEX ix_login_email_time ON login_log(email, login_time)';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -955 THEN RAISE; END IF;   -- już istnieje
END;
/


/* =====================================================================
   1. USUNIĘCIE STAREGO PAKIETU I TYPÓW
   ===================================================================== */
BEGIN
  FOR p IN (SELECT object_name FROM user_objects
             WHERE object_type = 'PACKAGE' AND object_name = 'PKG_KLIENCI')
  LOOP
    EXECUTE IMMEDIATE 'DROP PACKAGE pkg_klienci';
  END LOOP;

  FOR t IN (SELECT type_name FROM user_types
             WHERE type_name IN ('T_KARTA_TAB','T_KARTA','T_PROFIL_KLIENTA')
             ORDER BY CASE WHEN type_name LIKE '%TAB' THEN 0 ELSE 1 END)
  LOOP
    EXECUTE IMMEDIATE 'DROP TYPE ' || t.type_name || ' FORCE';
  END LOOP;
END;
/


/* =====================================================================
   2. TYPY OBIEKTOWE I KOLEKCJE
   ===================================================================== */
CREATE OR REPLACE TYPE t_profil_klienta AS OBJECT (
  customer_id            NUMBER,
  imie_nazwisko          VARCHAR2(110 CHAR),
  email                  VARCHAR2(254 CHAR),
  telefon                VARCHAR2(15 CHAR),
  klient_od              DATE,
  liczba_wypozyczen      NUMBER,
  wydano_lacznie         NUMBER(12,2),
  wydano_12m             NUMBER(12,2),
  poziom                 VARCHAR2(12 CHAR),
  rabat_proc             NUMBER(5,2),
  prog_nastepnego        NUMBER(12,2),        -- NULL = najwyższy poziom
  ulubiony_model         VARCHAR2(110 CHAR),
  ostatnie_wypozyczenie  DATE,
  szkody_z_winy          NUMBER,
  MEMBER FUNCTION do_nastepnego_poziomu RETURN NUMBER
);
/
SHOW ERRORS

CREATE OR REPLACE TYPE BODY t_profil_klienta AS
  MEMBER FUNCTION do_nastepnego_poziomu RETURN NUMBER IS
  BEGIN
    IF prog_nastepnego IS NULL THEN
      RETURN NULL;
    END IF;
    RETURN GREATEST(0, prog_nastepnego - wydano_12m);
  END do_nastepnego_poziomu;
END;
/
SHOW ERRORS

CREATE OR REPLACE TYPE t_karta AS OBJECT (
  payment_details_id   NUMBER,
  customer_id          NUMBER,
  klient               VARCHAR2(110 CHAR),
  email                VARCHAR2(254 CHAR),
  typ_karty            VARCHAR2(12 CHAR),
  ostatnie_cyfry       CHAR(4),
  data_waznosci        DATE,
  dni_do_wygasniecia   NUMBER                -- ujemne = karta już wygasła
);
/
CREATE OR REPLACE TYPE t_karta_tab AS TABLE OF t_karta;
/


/* =====================================================================
   3. SPECYFIKACJA PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE pkg_klienci AS

  c_max_prob_logowania   CONSTANT PLS_INTEGER := 5;     -- po tylu błędach blokada
  c_blokada_minut        CONSTANT PLS_INTEGER := 15;
  c_min_wiek_rejestracji CONSTANT PLS_INTEGER := 18;
  c_prog_srebrny         CONSTANT NUMBER := 1000;       -- wydatki z 12 miesięcy (zł)
  c_prog_zloty           CONSTANT NUMBER := 3000;
  c_prog_platynowy       CONSTANT NUMBER := 6000;

  e_nie_znaleziono     EXCEPTION;  PRAGMA EXCEPTION_INIT(e_nie_znaleziono,     -20006);
  e_zle_dane           EXCEPTION;  PRAGMA EXCEPTION_INIT(e_zle_dane,           -20020);
  e_duplikat           EXCEPTION;  PRAGMA EXCEPTION_INIT(e_duplikat,           -20021);
  e_haslo              EXCEPTION;  PRAGMA EXCEPTION_INIT(e_haslo,              -20022);
  e_konto_zablokowane  EXCEPTION;  PRAGMA EXCEPTION_INIT(e_konto_zablokowane,  -20023);
  e_karta              EXCEPTION;  PRAGMA EXCEPTION_INIT(e_karta,              -20024);
  e_klient_aktywny     EXCEPTION;  PRAGMA EXCEPTION_INIT(e_klient_aktywny,     -20025);

  /* ---------------- FUNKCJE ---------------- */

  -- F1: sygnatura zgodna z wymaganiami APEX (Custom Authentication Scheme)
  FUNCTION f_zaloguj (
    p_username  IN VARCHAR2,
    p_password  IN VARCHAR2
  ) RETURN BOOLEAN;

  -- F2: ADMIN / MANAGER / CLERK dla pracowników, CUSTOMER dla klientów, NULL gdy brak konta
  FUNCTION f_rola (p_email IN VARCHAR2) RETURN VARCHAR2;

  -- F3
  FUNCTION f_id_uzytkownika (p_email IN VARCHAR2) RETURN NUMBER;

  -- F4
  FUNCTION f_poziom_lojalnosci (p_customer_id IN customers.user_id%TYPE) RETURN VARCHAR2;

  -- F5
  FUNCTION f_rabat_lojalnosciowy (p_customer_id IN customers.user_id%TYPE) RETURN NUMBER;

  -- F6
  FUNCTION f_profil_klienta (p_customer_id IN customers.user_id%TYPE) RETURN t_profil_klienta;

  -- F7: karty ważne krócej niż p_dni (łącznie z już wygasłymi)
  FUNCTION f_karty_wygasajace (p_dni IN NUMBER DEFAULT 60) RETURN t_karta_tab;

  /* ---------------- PROCEDURY ---------------- */

  -- P1
  PROCEDURE p_zarejestruj_klienta (
    p_imie               IN  users.first_name%TYPE,
    p_nazwisko           IN  users.last_name%TYPE,
    p_ulica              IN  users.street%TYPE,
    p_miasto             IN  users.city%TYPE,
    p_wojewodztwo        IN  users.region%TYPE,
    p_kod_pocztowy       IN  users.zip_code%TYPE,
    p_data_urodzenia     IN  DATE,
    p_email              IN  users.email%TYPE,
    p_telefon            IN  users.phone_number%TYPE,
    p_haslo              IN  VARCHAR2,
    p_nr_prawa_jazdy     IN  customers.drivers_license_no%TYPE,
    p_data_prawa_jazdy   IN  DATE,
    o_user_id            OUT users.user_id%TYPE
  );

  -- P2
  PROCEDURE p_ustaw_haslo (
    p_user_id      IN users.user_id%TYPE,
    p_nowe_haslo   IN VARCHAR2
  );

  -- P3
  PROCEDURE p_zmien_haslo (
    p_email         IN VARCHAR2,
    p_stare_haslo   IN VARCHAR2,
    p_nowe_haslo    IN VARCHAR2
  );

  -- P4: numer karty tylko do walidacji – zapisywane są typ i 4 ostatnie cyfry
  PROCEDURE p_dodaj_karte (
    p_customer_id    IN  customers.user_id%TYPE,
    p_numer_karty    IN  VARCHAR2,
    p_wlasciciel     IN  payment_details.card_holder_name%TYPE,
    p_data_waznosci  IN  DATE,
    o_karta_id       OUT payment_details.payment_details_id%TYPE
  );

  -- P5
  PROCEDURE p_usun_karte (
    p_karta_id     IN payment_details.payment_details_id%TYPE,
    p_customer_id  IN customers.user_id%TYPE
  );

  -- P6
  PROCEDURE p_anonimizuj_klienta (
    p_customer_id  IN customers.user_id%TYPE
  );

END pkg_klienci;
/
SHOW ERRORS


/* =====================================================================
   4. CIAŁO PAKIETU
   ===================================================================== */
CREATE OR REPLACE PACKAGE BODY pkg_klienci AS

  /* =================== ELEMENTY PRYWATNE =================== */

  -- SHA-256 z solą (STANDARD_HASH jest funkcją SQL, stąd SELECT ... FROM dual)
  FUNCTION hashuj (p_haslo IN VARCHAR2, p_sol IN VARCHAR2) RETURN VARCHAR2 IS
    l_hash  VARCHAR2(64);
  BEGIN
    SELECT RAWTOHEX(STANDARD_HASH(p_sol || p_haslo, 'SHA256')) INTO l_hash FROM dual;
    RETURN l_hash;
  END hashuj;

  -- Nowy hash z losową solą: S1$<16 znaków soli>$<64 znaki hasha>
  FUNCTION zbuduj_hash (p_haslo IN VARCHAR2) RETURN VARCHAR2 IS
    l_sol  VARCHAR2(16) := DBMS_RANDOM.STRING('X', 16);
  BEGIN
    RETURN 'S1$' || l_sol || '$' || hashuj(p_haslo, l_sol);
  END zbuduj_hash;

  FUNCTION haslo_poprawne (p_haslo IN VARCHAR2, p_zapisany IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    IF p_haslo IS NULL OR p_zapisany IS NULL OR SUBSTR(p_zapisany, 1, 3) <> 'S1$' THEN
      RETURN FALSE;
    END IF;
    RETURN hashuj(p_haslo, SUBSTR(p_zapisany, 4, 16)) = SUBSTR(p_zapisany, 21);
  END haslo_poprawne;

  PROCEDURE sprawdz_sile_hasla (p_haslo IN VARCHAR2) IS
  BEGIN
    IF p_haslo IS NULL
    OR LENGTH(p_haslo) < 8
    OR NOT REGEXP_LIKE(p_haslo, '[[:upper:]]')
    OR NOT REGEXP_LIKE(p_haslo, '[[:lower:]]')
    OR NOT REGEXP_LIKE(p_haslo, '[[:digit:]]')
    THEN
      RAISE_APPLICATION_ERROR(-20022,
        'Hasło musi mieć min. 8 znaków, w tym wielką literę, małą literę i cyfrę.');
    END IF;
  END sprawdz_sile_hasla;

  -- Zapis próby logowania – transakcja autonomiczna (zostaje także przy błędzie)
  PROCEDURE zapisz_logowanie (p_email IN VARCHAR2, p_sukces IN CHAR) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO login_log (email, success, ip_address)
    VALUES (SUBSTR(p_email, 1, 254), p_sukces, SYS_CONTEXT('USERENV', 'IP_ADDRESS'));
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN ROLLBACK;
  END zapisz_logowanie;

  -- Blokada: >= c_max_prob_logowania nieudanych prób w ostatnich c_blokada_minut,
  -- licząc tylko próby po ostatnim udanym logowaniu
  FUNCTION konto_zablokowane (p_email IN VARCHAR2) RETURN BOOLEAN IS
    l_ost_sukces  TIMESTAMP;
    l_bledy       NUMBER;
  BEGIN
    SELECT MAX(login_time) INTO l_ost_sukces
      FROM login_log WHERE email = p_email AND success = 'Y';

    SELECT COUNT(*)
      INTO l_bledy
      FROM login_log
     WHERE email   = p_email
       AND success = 'N'
       AND login_time > SYSTIMESTAMP - NUMTODSINTERVAL(c_blokada_minut, 'MINUTE')
       AND login_time > NVL(l_ost_sukces, TIMESTAMP '1900-01-01 00:00:00');

    RETURN l_bledy >= c_max_prob_logowania;
  END konto_zablokowane;

  PROCEDURE sprawdz_klienta (p_customer_id IN NUMBER) IS
    l_ile  NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_ile FROM customers WHERE user_id = p_customer_id;
    IF l_ile = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono klienta o ID ' || p_customer_id || '.');
    END IF;
  END sprawdz_klienta;

  -- Wydatki na najem w ostatnich 12 miesiącach (podstawa poziomu lojalności)
  FUNCTION wydatki_12m (p_customer_id IN NUMBER) RETURN NUMBER IS
    l_suma  NUMBER;
  BEGIN
    SELECT NVL(SUM(t.amount), 0)
      INTO l_suma
      FROM transactions t
      JOIN bookings b ON b.booking_id = t.booking_id
     WHERE b.customer_id       = p_customer_id
       AND t.transaction_type  = 'PAYMENT'
       AND t.transaction_date >= ADD_MONTHS(TRUNC(SYSDATE), -12);
    RETURN l_suma;
  END wydatki_12m;

  PROCEDURE oblicz_poziom (
    p_kwota  IN  NUMBER,
    o_poziom OUT VARCHAR2,
    o_rabat  OUT NUMBER,
    o_prog   OUT NUMBER
  ) IS
  BEGIN
    IF p_kwota >= c_prog_platynowy THEN
      o_poziom := 'PLATYNOWY'; o_rabat := 15; o_prog := NULL;
    ELSIF p_kwota >= c_prog_zloty THEN
      o_poziom := 'ZLOTY';     o_rabat := 10; o_prog := c_prog_platynowy;
    ELSIF p_kwota >= c_prog_srebrny THEN
      o_poziom := 'SREBRNY';   o_rabat := 5;  o_prog := c_prog_zloty;
    ELSE
      o_poziom := 'STANDARD';  o_rabat := 0;  o_prog := c_prog_srebrny;
    END IF;
  END oblicz_poziom;

  -- Algorytm Luhna (suma kontrolna numerów kart)
  FUNCTION luhn_ok (p_numer IN VARCHAR2) RETURN BOOLEAN IS
    l_suma     PLS_INTEGER := 0;
    l_cyfra    PLS_INTEGER;
    l_podwoj   BOOLEAN := FALSE;
  BEGIN
    FOR i IN REVERSE 1 .. LENGTH(p_numer) LOOP
      l_cyfra := TO_NUMBER(SUBSTR(p_numer, i, 1));
      IF l_podwoj THEN
        l_cyfra := l_cyfra * 2;
        IF l_cyfra > 9 THEN
          l_cyfra := l_cyfra - 9;
        END IF;
      END IF;
      l_suma   := l_suma + l_cyfra;
      l_podwoj := NOT l_podwoj;
    END LOOP;
    RETURN MOD(l_suma, 10) = 0;
  END luhn_ok;

  -- Typ karty z prefiksu (BIN); NULL = nieobsługiwany
  FUNCTION typ_karty (p_numer IN VARCHAR2) RETURN VARCHAR2 IS
    l_p2  PLS_INTEGER := TO_NUMBER(SUBSTR(p_numer, 1, 2));
    l_p4  PLS_INTEGER := TO_NUMBER(SUBSTR(p_numer, 1, 4));
  BEGIN
    IF SUBSTR(p_numer, 1, 1) = '4' THEN
      RETURN 'VISA';
    ELSIF l_p2 IN (34, 37) THEN
      RETURN 'AMEX';
    ELSIF l_p2 BETWEEN 51 AND 55 OR l_p4 BETWEEN 2221 AND 2720 THEN
      RETURN 'MASTERCARD';
    ELSIF l_p2 IN (50, 56, 57, 58) OR SUBSTR(p_numer, 1, 1) = '6' THEN
      RETURN 'MAESTRO';
    END IF;
    RETURN NULL;
  END typ_karty;


  /* =================== FUNKCJE PUBLICZNE =================== */

  -- F1
  FUNCTION f_zaloguj (
    p_username  IN VARCHAR2,
    p_password  IN VARCHAR2
  ) RETURN BOOLEAN IS
    l_email  VARCHAR2(254) := LOWER(TRIM(p_username));
    l_hash   users.password_hash%TYPE;
    l_ok     BOOLEAN;
  BEGIN
    IF l_email IS NULL OR p_password IS NULL THEN
      RETURN FALSE;
    END IF;

    IF konto_zablokowane(l_email) THEN
      RAISE_APPLICATION_ERROR(-20023,
        'Konto zablokowane po ' || c_max_prob_logowania || ' nieudanych próbach logowania. '
        || 'Spróbuj ponownie za ' || c_blokada_minut || ' minut.');
    END IF;

    BEGIN
      SELECT password_hash INTO l_hash FROM users WHERE LOWER(email) = l_email;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN l_hash := NULL;   -- nie zdradzamy, czy konto istnieje
    END;

    l_ok := l_hash IS NOT NULL AND haslo_poprawne(p_password, l_hash);
    zapisz_logowanie(l_email, CASE WHEN l_ok THEN 'Y' ELSE 'N' END);
    RETURN l_ok;
  END f_zaloguj;

  -- F2
  FUNCTION f_rola (p_email IN VARCHAR2) RETURN VARCHAR2 IS
    l_rola  employees.employee_role%TYPE;
    l_ile   NUMBER;
  BEGIN
    SELECT e.employee_role
      INTO l_rola
      FROM employees e
      JOIN users u ON u.user_id = e.user_id
     WHERE LOWER(u.email) = LOWER(TRIM(p_email));
    RETURN l_rola;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      SELECT COUNT(*)
        INTO l_ile
        FROM customers c
        JOIN users u ON u.user_id = c.user_id
       WHERE LOWER(u.email) = LOWER(TRIM(p_email));
      RETURN CASE WHEN l_ile > 0 THEN 'CUSTOMER' END;
  END f_rola;

  -- F3
  FUNCTION f_id_uzytkownika (p_email IN VARCHAR2) RETURN NUMBER IS
    l_id  users.user_id%TYPE;
  BEGIN
    SELECT user_id INTO l_id FROM users WHERE LOWER(email) = LOWER(TRIM(p_email));
    RETURN l_id;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END f_id_uzytkownika;

  -- F4
  FUNCTION f_poziom_lojalnosci (p_customer_id IN customers.user_id%TYPE) RETURN VARCHAR2 IS
    l_poziom  VARCHAR2(12);
    l_rabat   NUMBER;
    l_prog    NUMBER;
  BEGIN
    sprawdz_klienta(p_customer_id);
    oblicz_poziom(wydatki_12m(p_customer_id), l_poziom, l_rabat, l_prog);
    RETURN l_poziom;
  END f_poziom_lojalnosci;

  -- F5
  FUNCTION f_rabat_lojalnosciowy (p_customer_id IN customers.user_id%TYPE) RETURN NUMBER IS
    l_poziom  VARCHAR2(12);
    l_rabat   NUMBER;
    l_prog    NUMBER;
  BEGIN
    sprawdz_klienta(p_customer_id);
    oblicz_poziom(wydatki_12m(p_customer_id), l_poziom, l_rabat, l_prog);
    RETURN l_rabat;
  END f_rabat_lojalnosciowy;

  -- F6
  FUNCTION f_profil_klienta (p_customer_id IN customers.user_id%TYPE) RETURN t_profil_klienta IS
    l_nazwa      VARCHAR2(110);
    l_email      users.email%TYPE;
    l_telefon    users.phone_number%TYPE;
    l_od         DATE;
    l_liczba     NUMBER;
    l_lacznie    NUMBER;
    l_12m        NUMBER;
    l_poziom     VARCHAR2(12);
    l_rabat      NUMBER;
    l_prog       NUMBER;
    l_ulubiony   VARCHAR2(110);
    l_ostatnie   DATE;
    l_szkody     NUMBER;
  BEGIN
    BEGIN
      SELECT u.first_name || ' ' || u.last_name, u.email, u.phone_number, u.created_at
        INTO l_nazwa, l_email, l_telefon, l_od
        FROM customers c JOIN users u ON u.user_id = c.user_id
       WHERE c.user_id = p_customer_id;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono klienta o ID ' || p_customer_id || '.');
    END;

    SELECT COUNT(*), MAX(start_date)
      INTO l_liczba, l_ostatnie
      FROM bookings
     WHERE customer_id = p_customer_id
       AND booking_status <> 'CANCELLED';

    SELECT NVL(SUM(t.amount), 0)
      INTO l_lacznie
      FROM transactions t
      JOIN bookings b ON b.booking_id = t.booking_id
     WHERE b.customer_id = p_customer_id
       AND t.transaction_type IN ('PAYMENT', 'DAMAGE_FEE');

    l_12m := wydatki_12m(p_customer_id);
    oblicz_poziom(l_12m, l_poziom, l_rabat, l_prog);

    -- najczęściej wybierany model (przy remisie – ostatnio wybrany)
    BEGIN
      SELECT auto
        INTO l_ulubiony
        FROM (SELECT m.make_name || ' ' || vt.model_name AS auto
                FROM bookings b
                JOIN vehicles v       ON v.vehicle_id       = b.vehicle_id
                JOIN vehicle_types vt ON vt.vehicle_type_id = v.vehicle_type_id
                JOIN makes m          ON m.make_id          = vt.make_id
               WHERE b.customer_id = p_customer_id
                 AND b.booking_status <> 'CANCELLED'
               GROUP BY m.make_name, vt.model_name
               ORDER BY COUNT(*) DESC, MAX(b.start_date) DESC)
       WHERE ROWNUM = 1;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN l_ulubiony := NULL;
    END;

    SELECT COUNT(*)
      INTO l_szkody
      FROM damages d
      JOIN bookings b ON b.booking_id = d.booking_id
     WHERE b.customer_id = p_customer_id
       AND d.charged_to_customer = 'Y';

    RETURN t_profil_klienta(p_customer_id, l_nazwa, l_email, l_telefon, l_od,
                            l_liczba, l_lacznie, l_12m, l_poziom, l_rabat, l_prog,
                            l_ulubiony, l_ostatnie, l_szkody);
  END f_profil_klienta;

  -- F7
  FUNCTION f_karty_wygasajace (p_dni IN NUMBER DEFAULT 60) RETURN t_karta_tab IS
    l_wynik  t_karta_tab;
  BEGIN
    IF p_dni IS NULL OR p_dni < 0 THEN
      RAISE_APPLICATION_ERROR(-20020, 'Liczba dni musi być nieujemna.');
    END IF;

    SELECT t_karta(pd.payment_details_id, pd.customer_id,
                   u.first_name || ' ' || u.last_name, u.email,
                   pd.card_type, pd.card_last4, pd.expiry_date,
                   pd.expiry_date - TRUNC(SYSDATE))
      BULK COLLECT INTO l_wynik
      FROM payment_details pd
      JOIN users u ON u.user_id = pd.customer_id
     WHERE pd.expiry_date <= TRUNC(SYSDATE) + p_dni
     ORDER BY pd.expiry_date;

    RETURN l_wynik;
  END f_karty_wygasajace;


  /* =================== PROCEDURY PUBLICZNE =================== */

  -- P1
  PROCEDURE p_zarejestruj_klienta (
    p_imie               IN  users.first_name%TYPE,
    p_nazwisko           IN  users.last_name%TYPE,
    p_ulica              IN  users.street%TYPE,
    p_miasto             IN  users.city%TYPE,
    p_wojewodztwo        IN  users.region%TYPE,
    p_kod_pocztowy       IN  users.zip_code%TYPE,
    p_data_urodzenia     IN  DATE,
    p_email              IN  users.email%TYPE,
    p_telefon            IN  users.phone_number%TYPE,
    p_haslo              IN  VARCHAR2,
    p_nr_prawa_jazdy     IN  customers.drivers_license_no%TYPE,
    p_data_prawa_jazdy   IN  DATE,
    o_user_id            OUT users.user_id%TYPE
  ) IS
    l_email    VARCHAR2(254) := LOWER(TRIM(p_email));
    l_telefon  VARCHAR2(30)  := REGEXP_REPLACE(p_telefon, '[[:space:]-]', '');
    l_prawo    VARCHAR2(20)  := UPPER(TRIM(p_nr_prawa_jazdy));
    l_hash     users.password_hash%TYPE;
    l_ile      NUMBER;
    l_kod      NUMBER;
    l_msg      VARCHAR2(4000);
    l_bt       VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_rejestracja;

    IF TRIM(p_imie) IS NULL OR TRIM(p_nazwisko) IS NULL OR TRIM(p_ulica) IS NULL
    OR TRIM(p_miasto) IS NULL OR TRIM(p_wojewodztwo) IS NULL OR p_data_urodzenia IS NULL
    OR l_prawo IS NULL OR p_data_prawa_jazdy IS NULL
    THEN
      RAISE_APPLICATION_ERROR(-20020, 'Wypełnij wszystkie wymagane pola formularza.');
    END IF;

    IF l_email IS NULL OR NOT REGEXP_LIKE(l_email, '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$') THEN
      RAISE_APPLICATION_ERROR(-20020, 'Nieprawidłowy adres e-mail.');
    END IF;

    IF l_telefon IS NULL OR NOT REGEXP_LIKE(l_telefon, '^\+?[0-9]{9,14}$') THEN
      RAISE_APPLICATION_ERROR(-20020, 'Nieprawidłowy numer telefonu (9–14 cyfr, opcjonalnie z +).');
    END IF;

    IF p_kod_pocztowy IS NULL OR NOT REGEXP_LIKE(p_kod_pocztowy, '^[0-9]{2}-[0-9]{3}$') THEN
      RAISE_APPLICATION_ERROR(-20020, 'Kod pocztowy musi mieć format 00-000.');
    END IF;

    IF MONTHS_BETWEEN(TRUNC(SYSDATE), p_data_urodzenia) / 12 < c_min_wiek_rejestracji THEN
      RAISE_APPLICATION_ERROR(-20020,
        'Rejestracja możliwa od ' || c_min_wiek_rejestracji || '. roku życia.');
    END IF;

    IF p_data_prawa_jazdy > TRUNC(SYSDATE)
    OR p_data_prawa_jazdy < ADD_MONTHS(p_data_urodzenia, 12 * 16) THEN
      RAISE_APPLICATION_ERROR(-20020, 'Nieprawidłowa data wydania prawa jazdy.');
    END IF;

    sprawdz_sile_hasla(p_haslo);

    SELECT COUNT(*) INTO l_ile FROM users WHERE LOWER(email) = l_email;
    IF l_ile > 0 THEN
      RAISE_APPLICATION_ERROR(-20021, 'Konto z adresem ' || l_email || ' już istnieje.');
    END IF;

    l_hash := zbuduj_hash(p_haslo);

    INSERT INTO users (first_name, last_name, street, city, region, zip_code,
                       date_of_birth, email, phone_number, password_hash)
    VALUES (TRIM(p_imie), TRIM(p_nazwisko), TRIM(p_ulica), TRIM(p_miasto), TRIM(p_wojewodztwo),
            p_kod_pocztowy, TRUNC(p_data_urodzenia), l_email, l_telefon, l_hash)
    RETURNING user_id INTO o_user_id;

    INSERT INTO customers (user_id, drivers_license_no, license_issue_date)
    VALUES (o_user_id, l_prawo, TRUNC(p_data_prawa_jazdy));

  EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_rejestracja;
      p_loguj_blad('PKG_KLIENCI.P_ZAREJESTRUJ_KLIENTA', l_kod, l_msg, l_bt);
      RAISE_APPLICATION_ERROR(-20021,
        'Klient z tym adresem e-mail lub numerem prawa jazdy jest już zarejestrowany.');
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_rejestracja;
      p_loguj_blad('PKG_KLIENCI.P_ZAREJESTRUJ_KLIENTA', l_kod, l_msg, l_bt);
      RAISE;
  END p_zarejestruj_klienta;

  -- P2
  PROCEDURE p_ustaw_haslo (
    p_user_id      IN users.user_id%TYPE,
    p_nowe_haslo   IN VARCHAR2
  ) IS
    l_hash  users.password_hash%TYPE;
    l_kod   NUMBER;
    l_msg   VARCHAR2(4000);
    l_bt    VARCHAR2(4000);
  BEGIN
    sprawdz_sile_hasla(p_nowe_haslo);
    l_hash := zbuduj_hash(p_nowe_haslo);

    UPDATE users SET password_hash = l_hash WHERE user_id = p_user_id;
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono użytkownika o ID ' || p_user_id || '.');
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      p_loguj_blad('PKG_KLIENCI.P_USTAW_HASLO', l_kod, l_msg, l_bt);
      RAISE;
  END p_ustaw_haslo;

  -- P3
  PROCEDURE p_zmien_haslo (
    p_email         IN VARCHAR2,
    p_stare_haslo   IN VARCHAR2,
    p_nowe_haslo    IN VARCHAR2
  ) IS
    l_id    users.user_id%TYPE;
    l_hash  users.password_hash%TYPE;
    l_kod   NUMBER;
    l_msg   VARCHAR2(4000);
    l_bt    VARCHAR2(4000);
  BEGIN
    BEGIN
      SELECT user_id, password_hash INTO l_id, l_hash
        FROM users WHERE LOWER(email) = LOWER(TRIM(p_email))
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono konta ' || p_email || '.');
    END;

    IF NOT haslo_poprawne(p_stare_haslo, l_hash) THEN
      RAISE_APPLICATION_ERROR(-20022, 'Obecne hasło jest nieprawidłowe.');
    END IF;

    IF p_nowe_haslo = p_stare_haslo THEN
      RAISE_APPLICATION_ERROR(-20022, 'Nowe hasło musi się różnić od obecnego.');
    END IF;

    sprawdz_sile_hasla(p_nowe_haslo);
    l_hash := zbuduj_hash(p_nowe_haslo);
    UPDATE users SET password_hash = l_hash WHERE user_id = l_id;
  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      p_loguj_blad('PKG_KLIENCI.P_ZMIEN_HASLO', l_kod, l_msg, l_bt);
      RAISE;
  END p_zmien_haslo;

  -- P4
  PROCEDURE p_dodaj_karte (
    p_customer_id    IN  customers.user_id%TYPE,
    p_numer_karty    IN  VARCHAR2,
    p_wlasciciel     IN  payment_details.card_holder_name%TYPE,
    p_data_waznosci  IN  DATE,
    o_karta_id       OUT payment_details.payment_details_id%TYPE
  ) IS
    l_numer   VARCHAR2(40) := REGEXP_REPLACE(p_numer_karty, '[[:space:]-]', '');
    l_typ     payment_details.card_type%TYPE;
    l_waznosc DATE := LAST_DAY(TRUNC(p_data_waznosci));
    l_ile     NUMBER;
    l_kod     NUMBER;
    l_msg     VARCHAR2(4000);
    l_bt      VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_karta;

    sprawdz_klienta(p_customer_id);

    IF l_numer IS NULL OR NOT REGEXP_LIKE(l_numer, '^[0-9]{13,19}$') THEN
      RAISE_APPLICATION_ERROR(-20024, 'Numer karty musi składać się z 13–19 cyfr.');
    END IF;

    IF NOT luhn_ok(l_numer) THEN
      RAISE_APPLICATION_ERROR(-20024, 'Numer karty jest nieprawidłowy (błędna suma kontrolna).');
    END IF;

    l_typ := typ_karty(l_numer);
    IF l_typ IS NULL THEN
      RAISE_APPLICATION_ERROR(-20024, 'Nieobsługiwany typ karty (akceptujemy VISA, Mastercard, AMEX, Maestro).');
    END IF;

    IF l_waznosc IS NULL OR l_waznosc < TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(-20024, 'Karta straciła ważność.');
    END IF;

    IF TRIM(p_wlasciciel) IS NULL THEN
      RAISE_APPLICATION_ERROR(-20020, 'Podaj imię i nazwisko właściciela karty.');
    END IF;

    SELECT COUNT(*)
      INTO l_ile
      FROM payment_details
     WHERE customer_id = p_customer_id
       AND card_last4  = SUBSTR(l_numer, -4)
       AND card_type   = l_typ
       AND expiry_date = l_waznosc;
    IF l_ile > 0 THEN
      RAISE_APPLICATION_ERROR(-20024, 'Ta karta jest już zapisana na koncie klienta.');
    END IF;

    INSERT INTO payment_details (customer_id, card_type, card_last4, card_holder_name, expiry_date)
    VALUES (p_customer_id, l_typ, SUBSTR(l_numer, -4), UPPER(TRIM(p_wlasciciel)), l_waznosc)
    RETURNING payment_details_id INTO o_karta_id;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_karta;
      -- w logu NIE zapisujemy numeru karty
      p_loguj_blad('PKG_KLIENCI.P_DODAJ_KARTE', l_kod, l_msg, l_bt);
      RAISE;
  END p_dodaj_karte;

  -- P5: mapowanie błędu systemowego ORA-02292 (naruszenie klucza obcego)
  PROCEDURE p_usun_karte (
    p_karta_id     IN payment_details.payment_details_id%TYPE,
    p_customer_id  IN customers.user_id%TYPE
  ) IS
    e_karta_uzyta  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_karta_uzyta, -2292);
    l_kod   NUMBER;
    l_msg   VARCHAR2(4000);
    l_bt    VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_usun_karte;

    DELETE FROM payment_details
     WHERE payment_details_id = p_karta_id
       AND customer_id        = p_customer_id;

    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20006,
        'Nie znaleziono karty ID ' || p_karta_id || ' na koncie klienta ' || p_customer_id || '.');
    END IF;

  EXCEPTION
    WHEN e_karta_uzyta THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_usun_karte;
      p_loguj_blad('PKG_KLIENCI.P_USUN_KARTE', l_kod, l_msg, l_bt);
      RAISE_APPLICATION_ERROR(-20024,
        'Karta była używana w płatnościach – ze względów księgowych nie można jej usunąć.');
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_usun_karte;
      p_loguj_blad('PKG_KLIENCI.P_USUN_KARTE', l_kod, l_msg, l_bt);
      RAISE;
  END p_usun_karte;

  -- P6: kursor FOR UPDATE + WHERE CURRENT OF
  PROCEDURE p_anonimizuj_klienta (
    p_customer_id  IN customers.user_id%TYPE
  ) IS
    CURSOR c_karty IS
      SELECT payment_details_id
        FROM payment_details
       WHERE customer_id = p_customer_id
         FOR UPDATE;

    l_id      users.user_id%TYPE;
    l_ile     NUMBER;
    l_uzyta   NUMBER;
    l_hash    users.password_hash%TYPE;
    l_kod     NUMBER;
    l_msg     VARCHAR2(4000);
    l_bt      VARCHAR2(4000);
  BEGIN
    SAVEPOINT sp_anonimizacja;

    BEGIN
      SELECT u.user_id INTO l_id
        FROM users u
       WHERE u.user_id = p_customer_id
         AND EXISTS (SELECT 1 FROM customers c WHERE c.user_id = u.user_id)
         FOR UPDATE;
    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Nie znaleziono klienta o ID ' || p_customer_id || '.');
    END;

    SELECT COUNT(*)
      INTO l_ile
      FROM bookings
     WHERE customer_id = p_customer_id
       AND booking_status IN ('RESERVED', 'ACTIVE');
    IF l_ile > 0 THEN
      RAISE_APPLICATION_ERROR(-20025,
        'Klient ma ' || l_ile || ' aktywnych lub przyszłych rezerwacji – anonimizacja niemożliwa.');
    END IF;

    -- losowe hasło: konto nie nadaje się już do logowania
    l_hash := zbuduj_hash(DBMS_RANDOM.STRING('X', 30) || 'Aa1');

    UPDATE users
       SET first_name    = 'Anonim',
           last_name     = 'Klient #' || p_customer_id,
           middle_name   = NULL,
           street        = '-',
           city          = '-',
           region        = '-',
           zip_code      = '00-000',
           date_of_birth = DATE '1900-01-01',
           email         = 'anonim' || p_customer_id || '@usuniety.invalid',
           phone_number  = '+48000000000',
           password_hash = l_hash
     WHERE user_id = p_customer_id;

    UPDATE customers
       SET drivers_license_no = 'ANON-' || p_customer_id
     WHERE user_id = p_customer_id;

    -- karty użyte w płatnościach zostają (księgowość) bez nazwiska, pozostałe są usuwane
    FOR r IN c_karty LOOP
      SELECT COUNT(*) INTO l_uzyta
        FROM transactions WHERE payment_details_id = r.payment_details_id;

      IF l_uzyta > 0 THEN
        UPDATE payment_details SET card_holder_name = 'ANONIM' WHERE CURRENT OF c_karty;
      ELSE
        DELETE FROM payment_details WHERE CURRENT OF c_karty;
      END IF;
    END LOOP;

  EXCEPTION
    WHEN OTHERS THEN
      l_kod := SQLCODE; l_msg := SQLERRM; l_bt := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
      ROLLBACK TO sp_anonimizacja;
      p_loguj_blad('PKG_KLIENCI.P_ANONIMIZUJ_KLIENTA', l_kod, l_msg, l_bt);
      RAISE;
  END p_anonimizuj_klienta;

END pkg_klienci;
/
SHOW ERRORS


/* =====================================================================
   5. HASŁA DEMONSTRACYJNE
   Użytkownicy z danych przykładowych dostają hasło: Haslo123!
   (tylko ci, którzy wciąż mają HASH_PLACEHOLDER – ponowne uruchomienie
    skryptu nie nadpisze zmienionych haseł)
   ===================================================================== */
BEGIN
  FOR u IN (SELECT user_id FROM users WHERE password_hash = 'HASH_PLACEHOLDER') LOOP
    pkg_klienci.p_ustaw_haslo(u.user_id, 'Haslo123!');
  END LOOP;
  COMMIT;
END;
/
