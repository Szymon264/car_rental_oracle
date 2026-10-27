/* =====================================================================
   TESTY PKG_KLIENCI
   Uruchom klawiszem F5 na świeżych danych (01 -> 02 -> 04 -> 06).
   Na końcu ROLLBACK – zostają tylko wpisy w ERROR_LOG i LOGIN_LOG
   (oba zapisywane autonomicznie, celowo).
   Hasło wszystkich użytkowników z danych przykładowych: Haslo123!
   ===================================================================== */
SET SERVEROUTPUT ON SIZE UNLIMITED
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';


/* ---------------------------------------------------------------------
   TEST 1 – F1 f_zaloguj, F2 f_rola, F3 f_id_uzytkownika
   Oczekiwane: dobre hasło = TAK, złe = NIE, e-mail wielkimi literami = TAK,
               role: MANAGER, ADMIN, CUSTOMER, (brak); ID Anny = 1
   --------------------------------------------------------------------- */
DECLARE
  FUNCTION tak_nie (p BOOLEAN) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN p THEN 'TAK' ELSE 'NIE' END;
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 1: logowanie i role ===');
  DBMS_OUTPUT.PUT_LINE('Dobre hasło:        ' ||
    tak_nie(pkg_klienci.f_zaloguj('anna.kowalska@wypozyczalnia.pl', 'Haslo123!')));
  DBMS_OUTPUT.PUT_LINE('Złe hasło:          ' ||
    tak_nie(pkg_klienci.f_zaloguj('anna.kowalska@wypozyczalnia.pl', 'haslo123!')));
  DBMS_OUTPUT.PUT_LINE('E-mail wielkimi:    ' ||
    tak_nie(pkg_klienci.f_zaloguj('  ANNA.KOWALSKA@wypozyczalnia.pl ', 'Haslo123!')));

  DBMS_OUTPUT.PUT_LINE('Rola Anny:          ' || pkg_klienci.f_rola('anna.kowalska@wypozyczalnia.pl'));
  DBMS_OUTPUT.PUT_LINE('Rola Tomasza:       ' || pkg_klienci.f_rola('tomasz.wojcik@wypozyczalnia.pl'));
  DBMS_OUTPUT.PUT_LINE('Rola Michała:       ' || pkg_klienci.f_rola('michal.kaminski@gmail.com'));
  DBMS_OUTPUT.PUT_LINE('Rola nieznanego:    ' || NVL(pkg_klienci.f_rola('nikt@nigdzie.pl'), '(brak konta)'));
  DBMS_OUTPUT.PUT_LINE('ID Anny:            ' || pkg_klienci.f_id_uzytkownika('anna.kowalska@wypozyczalnia.pl'));
END;
/


/* ---------------------------------------------------------------------
   TEST 2 – blokada konta po 5 nieudanych próbach
   (losowy e-mail, żeby test działał przy każdym uruchomieniu)
   Oczekiwane: 5 x NIE, szósta próba = błąd -20023
   --------------------------------------------------------------------- */
DECLARE
  l_email  VARCHAR2(100) := 'blokada.' || LOWER(DBMS_RANDOM.STRING('X', 6)) || '@test.pl';
  l_ok     BOOLEAN;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 2: blokada konta (' || l_email || ') ===');
  FOR i IN 1 .. pkg_klienci.c_max_prob_logowania LOOP
    l_ok := pkg_klienci.f_zaloguj(l_email, 'ZleHaslo' || i);
    DBMS_OUTPUT.PUT_LINE('Próba ' || i || ': ' || CASE WHEN l_ok THEN 'TAK' ELSE 'NIE' END);
  END LOOP;

  BEGIN
    l_ok := pkg_klienci.f_zaloguj(l_email, 'CokolwiekA1');
    DBMS_OUTPUT.PUT_LINE('BŁĄD TESTU – konto powinno być zablokowane');
  EXCEPTION
    WHEN pkg_klienci.e_konto_zablokowane THEN
      DBMS_OUTPUT.PUT_LINE('OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 3 – P1 rejestracja + walidacje
   Oczekiwane: nowe konto (ID >= 100), logowanie nowym hasłem = TAK, rola CUSTOMER;
               duplikat e-maila = -20021; słabe hasło = -20022;
               17-latek = -20020; zły kod pocztowy = -20020
   --------------------------------------------------------------------- */
DECLARE
  l_id   users.user_id%TYPE;
  l_id2  users.user_id%TYPE;

  PROCEDURE rejestruj (p_email VARCHAR2, p_haslo VARCHAR2, p_ur DATE, p_kod VARCHAR2,
                       p_prawo VARCHAR2, o_id OUT NUMBER) IS
  BEGIN
    pkg_klienci.p_zarejestruj_klienta(
      p_imie => 'Jan', p_nazwisko => 'Testowy', p_ulica => 'ul. Próbna 5',
      p_miasto => 'Rzeszów', p_wojewodztwo => 'podkarpackie', p_kod_pocztowy => p_kod,
      p_data_urodzenia => p_ur, p_email => p_email, p_telefon => '600 123 456',
      p_haslo => p_haslo, p_nr_prawa_jazdy => p_prawo,
      p_data_prawa_jazdy => DATE '2020-05-05', o_user_id => o_id);
  END;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 3: rejestracja ===');
  rejestruj('Jan.Testowy@Test.pl', 'Bezpieczne1', DATE '1999-03-03', '35-100', 'pl-99999/20', l_id);
  DBMS_OUTPUT.PUT_LINE('Zarejestrowano klienta ID ' || l_id
    || ', logowanie: ' || CASE WHEN pkg_klienci.f_zaloguj('jan.testowy@test.pl', 'Bezpieczne1')
                               THEN 'TAK' ELSE 'NIE' END
    || ', rola: ' || pkg_klienci.f_rola('jan.testowy@test.pl'));

  BEGIN
    rejestruj('jan.testowy@test.pl', 'Bezpieczne1', DATE '1999-03-03', '35-100', 'PL-88888/20', l_id2);
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_duplikat THEN
    DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    rejestruj('inny@test.pl', 'haslo', DATE '1999-03-03', '35-100', 'PL-77777/20', l_id2);
    DBMS_OUTPUT.PUT_LINE('b) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_haslo THEN
    DBMS_OUTPUT.PUT_LINE('b) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    rejestruj('mlody@test.pl', 'Bezpieczne1', ADD_MONTHS(TRUNC(SYSDATE), -12 * 17), '35-100',
              'PL-66666/20', l_id2);
    DBMS_OUTPUT.PUT_LINE('c) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_zle_dane THEN
    DBMS_OUTPUT.PUT_LINE('c) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    rejestruj('kod@test.pl', 'Bezpieczne1', DATE '1999-03-03', '35100', 'PL-55555/20', l_id2);
    DBMS_OUTPUT.PUT_LINE('d) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_zle_dane THEN
    DBMS_OUTPUT.PUT_LINE('d) OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 4 – P3 zmiana hasła
   Oczekiwane: złe stare hasło = -20022; po zmianie: nowe = TAK, stare = NIE
   --------------------------------------------------------------------- */
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 4: zmiana hasła ===');
  BEGIN
    pkg_klienci.p_zmien_haslo('jan.testowy@test.pl', 'ZleStare1', 'NoweHaslo2');
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_haslo THEN
    DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  pkg_klienci.p_zmien_haslo('jan.testowy@test.pl', 'Bezpieczne1', 'NoweHaslo2');
  DBMS_OUTPUT.PUT_LINE('Nowe hasło: ' ||
    CASE WHEN pkg_klienci.f_zaloguj('jan.testowy@test.pl', 'NoweHaslo2') THEN 'TAK' ELSE 'NIE' END);
  DBMS_OUTPUT.PUT_LINE('Stare hasło: ' ||
    CASE WHEN pkg_klienci.f_zaloguj('jan.testowy@test.pl', 'Bezpieczne1') THEN 'TAK' ELSE 'NIE' END);
END;
/


/* ---------------------------------------------------------------------
   TEST 5 – P4 / P5 karty
   Oczekiwane: VISA ****1111, MASTERCARD ****4444, AMEX ****0005;
               zła suma kontrolna = -20024; karta wygasła = -20024; duplikat = -20024;
               usunięcie nieużywanej karty = OK; karty 1 (użyta w płatnościach) = -20024;
               karty innego klienta = -20006
   --------------------------------------------------------------------- */
DECLARE
  l_klient  users.user_id%TYPE := pkg_klienci.f_id_uzytkownika('jan.testowy@test.pl');
  l_k1      payment_details.payment_details_id%TYPE;
  l_k2      payment_details.payment_details_id%TYPE;
  l_k3      payment_details.payment_details_id%TYPE;
  l_x       payment_details.payment_details_id%TYPE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 5: karty płatnicze ===');
  pkg_klienci.p_dodaj_karte(l_klient, '4111 1111 1111 1111', 'Jan Testowy', DATE '2029-08-01', l_k1);
  pkg_klienci.p_dodaj_karte(l_klient, '5555-5555-5555-4444', 'Jan Testowy', DATE '2028-02-01', l_k2);
  pkg_klienci.p_dodaj_karte(l_klient, '378282246310005',     'Jan Testowy', DATE '2030-12-01', l_k3);

  FOR k IN (SELECT payment_details_id, card_type, card_last4, card_holder_name, expiry_date
              FROM payment_details WHERE customer_id = l_klient ORDER BY payment_details_id)
  LOOP
    DBMS_OUTPUT.PUT_LINE('  karta ' || k.payment_details_id || ': ' || RPAD(k.card_type, 11)
      || '****' || k.card_last4 || '  ' || k.card_holder_name || '  ważna do ' || k.expiry_date);
  END LOOP;

  BEGIN
    pkg_klienci.p_dodaj_karte(l_klient, '4111111111111112', 'Jan Testowy', DATE '2029-01-01', l_x);
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_karta THEN
    DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_klienci.p_dodaj_karte(l_klient, '4012888888881881', 'Jan Testowy', DATE '2020-01-01', l_x);
    DBMS_OUTPUT.PUT_LINE('b) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_karta THEN
    DBMS_OUTPUT.PUT_LINE('b) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_klienci.p_dodaj_karte(l_klient, '4111111111111111', 'Jan Testowy', DATE '2029-08-15', l_x);
    DBMS_OUTPUT.PUT_LINE('c) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_karta THEN
    DBMS_OUTPUT.PUT_LINE('c) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  pkg_klienci.p_usun_karte(l_k3, l_klient);
  DBMS_OUTPUT.PUT_LINE('Usunięto kartę AMEX (ID ' || l_k3 || ')');

  BEGIN
    pkg_klienci.p_usun_karte(1, 5);
    DBMS_OUTPUT.PUT_LINE('d) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_karta THEN
    DBMS_OUTPUT.PUT_LINE('d) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  BEGIN
    pkg_klienci.p_usun_karte(2, 5);   -- karta 2 należy do klienta 6
    DBMS_OUTPUT.PUT_LINE('e) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_nie_znaleziono THEN
    DBMS_OUTPUT.PUT_LINE('e) OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 6 – F4 / F5 / F6 lojalność i profil
   Klient 5: najem z 12 mies. = 636 + 996 = 1632 zł -> SREBRNY, 5%,
             do ZŁOTEGO brakuje 1368 zł; wydano łącznie 2832 (z karą 1200);
             2 wypożyczenia, ulubiony model Toyota RAV4 (remis -> ostatni), 1 szkoda z winy
   Klient 7: 777 zł -> STANDARD, 0%
   --------------------------------------------------------------------- */
DECLARE
  l_p  t_profil_klienta;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 6: lojalność i profil ===');
  DBMS_OUTPUT.PUT_LINE('Klient 7: ' || pkg_klienci.f_poziom_lojalnosci(7)
                       || ', rabat ' || pkg_klienci.f_rabat_lojalnosciowy(7) || '%');

  l_p := pkg_klienci.f_profil_klienta(5);
  DBMS_OUTPUT.PUT_LINE('Profil: ' || l_p.imie_nazwisko || ' <' || l_p.email || '>');
  DBMS_OUTPUT.PUT_LINE('  wypożyczeń: ' || l_p.liczba_wypozyczen
                       || ', ostatnie: ' || l_p.ostatnie_wypozyczenie
                       || ', ulubiony: ' || l_p.ulubiony_model);
  DBMS_OUTPUT.PUT_LINE('  wydano łącznie: ' || l_p.wydano_lacznie
                       || ' zł, w 12 mies.: ' || l_p.wydano_12m || ' zł');
  DBMS_OUTPUT.PUT_LINE('  poziom: ' || l_p.poziom || ' (' || l_p.rabat_proc || '%), do następnego: '
                       || l_p.do_nastepnego_poziomu() || ' zł');
  DBMS_OUTPUT.PUT_LINE('  szkody z winy klienta: ' || l_p.szkody_z_winy);
END;
/

-- Poziomy wszystkich klientów w jednym zapytaniu (funkcje pakietu w SQL)
SELECT c.user_id, u.first_name || ' ' || u.last_name AS klient,
       pkg_klienci.f_poziom_lojalnosci(c.user_id)   AS poziom,
       pkg_klienci.f_rabat_lojalnosciowy(c.user_id) AS rabat_proc
  FROM customers c JOIN users u ON u.user_id = c.user_id
 ORDER BY c.user_id;


/* ---------------------------------------------------------------------
   TEST 7 – F7 karty wygasające w ciągu 450 dni
   Oczekiwane: karta 5 (VISA ****3047, 2027-06-30) i karta 2 (MASTERCARD ****1934, 2027-11-30)
   --------------------------------------------------------------------- */
SELECT payment_details_id, klient, typ_karty, ostatnie_cyfry, data_waznosci, dni_do_wygasniecia
  FROM TABLE(pkg_klienci.f_karty_wygasajace(450));


/* ---------------------------------------------------------------------
   TEST 8 – P6 anonimizacja
   Oczekiwane: klient 9 (trwające wypożyczenie) = -20025;
               klient 7: dane zastąpione, karta 3 (użyta) -> ANONIM, nowa nieużyta karta usunięta,
               logowanie starym hasłem = NIE
   --------------------------------------------------------------------- */
DECLARE
  l_karta  payment_details.payment_details_id%TYPE;
  l_txt    VARCHAR2(400);
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 8: anonimizacja (RODO) ===');
  BEGIN
    pkg_klienci.p_anonimizuj_klienta(9);
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION WHEN pkg_klienci.e_klient_aktywny THEN
    DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  pkg_klienci.p_dodaj_karte(7, '5555555555554444', 'Krzysztof Zieliński', DATE '2029-01-01', l_karta);
  pkg_klienci.p_anonimizuj_klienta(7);

  SELECT u.first_name || ' ' || u.last_name || ' | ' || u.email || ' | ' || u.phone_number
         || ' | ' || c.drivers_license_no
    INTO l_txt
    FROM users u JOIN customers c ON c.user_id = u.user_id WHERE u.user_id = 7;
  DBMS_OUTPUT.PUT_LINE('Po anonimizacji: ' || l_txt);

  FOR k IN (SELECT payment_details_id, card_holder_name FROM payment_details WHERE customer_id = 7) LOOP
    DBMS_OUTPUT.PUT_LINE('  pozostała karta ' || k.payment_details_id || ': ' || k.card_holder_name);
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('Logowanie starym hasłem: ' ||
    CASE WHEN pkg_klienci.f_zaloguj('anonim7@usuniety.invalid', 'Haslo123!') THEN 'TAK' ELSE 'NIE' END);
END;
/


/* ---------------------------------------------------------------------
   TEST 9 – dzienniki
   --------------------------------------------------------------------- */
SELECT log_id, TO_CHAR(login_time, 'HH24:MI:SS') AS czas, email, success
  FROM login_log
 ORDER BY log_id DESC
 FETCH FIRST 12 ROWS ONLY;

SELECT log_id, TO_CHAR(log_date, 'HH24:MI:SS') AS czas, source_name, error_code, error_message
  FROM error_log
 WHERE source_name LIKE 'PKG_KLIENCI%'
 ORDER BY log_id DESC
 FETCH FIRST 15 ROWS ONLY;


-- Przywrócenie danych przykładowych
ROLLBACK;
