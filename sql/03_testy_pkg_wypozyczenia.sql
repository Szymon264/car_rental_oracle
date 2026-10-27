/* =====================================================================
   TESTY PKG_WYPOZYCZENIA
   Uruchom w SQL Developerze klawiszem F5 (Run Script).
   Na końcu jest ROLLBACK – dane przykładowe wracają do stanu wyjściowego,
   zostają tylko wpisy w ERROR_LOG (zapisywane autonomicznie, celowo).
   Przy każdym teście w komentarzu jest OCZEKIWANY wynik.
   ===================================================================== */
SET SERVEROUTPUT ON SIZE UNLIMITED
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';


/* ---------------------------------------------------------------------
   TEST 1 – F1 f_czy_dostepne
   Oczekiwane: auto 2 = 0 (trwa wypożyczenie), auto 1 = 1, auto 5 = 0 (serwis)
   --------------------------------------------------------------------- */
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 1: dostępność aut ===');
  DBMS_OUTPUT.PUT_LINE('Auto 2 (wypożyczone): ' ||
    pkg_wypozyczenia.f_czy_dostepne(2, TRUNC(SYSDATE), TRUNC(SYSDATE) + 2));
  DBMS_OUTPUT.PUT_LINE('Auto 1 (wolne):       ' ||
    pkg_wypozyczenia.f_czy_dostepne(1, TRUNC(SYSDATE) + 1, TRUNC(SYSDATE) + 4));
  DBMS_OUTPUT.PUT_LINE('Auto 5 (w serwisie):  ' ||
    pkg_wypozyczenia.f_czy_dostepne(5, TRUNC(SYSDATE) + 1, TRUNC(SYSDATE) + 4));
END;
/


/* ---------------------------------------------------------------------
   TEST 2 – F3 f_dostepne_auta (kolekcja obiektów użyta w zwykłym SELECT)
   Oczekiwane: 8 aut (bez auta 3 – rezerwacja 5–7.11 – i auta 5 – serwis),
               koszt_szacowany = 3 dni x stawka - 10% (kod JESIEN26)
   --------------------------------------------------------------------- */
SELECT *
  FROM TABLE(pkg_wypozyczenia.f_dostepne_auta(DATE '2026-11-05', DATE '2026-11-08',
                                              p_kod_promocji => 'JESIEN26'));

-- Tylko oddział 1, tylko osobowe. Oczekiwane: RZ 1234A, RZ 5678B, RZ 3RAV4
SELECT vehicle_id, nr_rejestracyjny, marka, model_auta, stawka_dzienna, koszt_szacowany
  FROM TABLE(pkg_wypozyczenia.f_dostepne_auta(DATE '2026-11-05', DATE '2026-11-08', 1, 'CAR'));


/* ---------------------------------------------------------------------
   TEST 3 – F2 f_oblicz_koszt (obiekt T_KOSZT i jego metoda opis())
   Oczekiwane:
     a) 4 dni x 159.00 zł = 636.00 zł, rabat 10% (-63.60 zł); RAZEM: 572.40 zł
     b) jak wyżej + spóźnienie 2 dni (+318.00 zł); RAZEM: 890.40 zł
     c) błąd -20003 (LATO26 nie obowiązuje w listopadzie)
   --------------------------------------------------------------------- */
DECLARE
  l_k  t_koszt;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 3: kalkulacja kosztu ===');

  l_k := pkg_wypozyczenia.f_oblicz_koszt(1, DATE '2026-11-10', DATE '2026-11-14', 'JESIEN26');
  DBMS_OUTPUT.PUT_LINE('a) ' || l_k.opis());

  l_k := pkg_wypozyczenia.f_oblicz_koszt(1, DATE '2026-11-10', DATE '2026-11-14', 'JESIEN26',
                                         p_data_zwrotu => DATE '2026-11-16');
  DBMS_OUTPUT.PUT_LINE('b) ' || l_k.opis());

  BEGIN
    l_k := pkg_wypozyczenia.f_oblicz_koszt(1, DATE '2026-11-10', DATE '2026-11-14', 'LATO26');
    DBMS_OUTPUT.PUT_LINE('c) BŁĄD TESTU – kod powinien zostać odrzucony');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_zly_kod_rabatowy THEN
      DBMS_OUTPUT.PUT_LINE('c) OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/

-- Ten sam obiekt użyty w SQL (np. do raportu w APEX)
SELECT t.k.liczba_dni AS dni, t.k.kwota_rabatu AS rabat, t.k.suma AS razem, t.k.opis() AS opis
  FROM (SELECT pkg_wypozyczenia.f_oblicz_koszt(4, DATE '2026-11-10', DATE '2026-11-13') AS k
          FROM dual) t;


/* ---------------------------------------------------------------------
   TEST 4 – F4 f_czy_klient_uprawniony
   Oczekiwane: klient 5 = 1, nowy 19-latek = 0, rezerwacja dla 19-latka = błąd -20004
   --------------------------------------------------------------------- */
DECLARE
  l_mlody  users.user_id%TYPE;
  l_rez    bookings.booking_id%TYPE;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 4: uprawnienia klienta ===');
  DBMS_OUTPUT.PUT_LINE('Klient 5: ' || pkg_wypozyczenia.f_czy_klient_uprawniony(5));

  INSERT INTO users (first_name, last_name, street, city, region, zip_code,
                     date_of_birth, email, phone_number, password_hash)
  VALUES ('Test', 'Mlody', 'ul. Testowa 1', 'Rzeszów', 'podkarpackie', '35-001',
          ADD_MONTHS(TRUNC(SYSDATE), -12 * 19), 'test.mlody@test.pl', '+48699000111', 'HASH')
  RETURNING user_id INTO l_mlody;

  INSERT INTO customers (user_id, drivers_license_no, license_issue_date)
  VALUES (l_mlody, 'TEST-0001', ADD_MONTHS(TRUNC(SYSDATE), -6));

  DBMS_OUTPUT.PUT_LINE('Klient 19 lat (ID ' || l_mlody || '): '
                       || pkg_wypozyczenia.f_czy_klient_uprawniony(l_mlody));

  BEGIN
    pkg_wypozyczenia.p_utworz_rezerwacje(l_mlody, 4, 2, TRUNC(SYSDATE) + 1, TRUNC(SYSDATE) + 3,
                                         o_booking_id => l_rez);
    DBMS_OUTPUT.PUT_LINE('BŁĄD TESTU – rezerwacja nie powinna powstać');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_klient_nieuprawniony THEN
      DBMS_OUTPUT.PUT_LINE('OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 5 – pełny cykl: P1 rezerwacja -> P3 wydanie -> P4 zwrot z poważną szkodą
   Auto 1 (Corolla, 159 zł/dzień), klient 5, pracownik 2, karta 1.
   Oczekiwane:
     - druga rezerwacja tego auta w tym terminie = błąd -20001
     - po wydaniu: status ACTIVE, auto RENTED, kaucja 500
     - zwrot 1 dzień po terminie: 3 dni x 159 = 477 + spóźnienie 159 = 636.00
     - kara 1500 (tylko szkoda z winy klienta) > kaucja 500 -> DAMAGE_FEE 1000, brak REFUND
     - auto w statusie MAINTENANCE, przebieg 45800, nowy wpis w MAINTENANCE
   --------------------------------------------------------------------- */
DECLARE
  l_rez     bookings.booking_id%TYPE;
  l_rez2    bookings.booking_id%TYPE;
  l_koszt   t_koszt;
  l_status  VARCHAR2(20);
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 5: rezerwacja -> wydanie -> zwrot ze szkodą ===');

  pkg_wypozyczenia.p_utworz_rezerwacje(
    p_customer_id => 5, p_vehicle_id => 1, p_employee_id => 2,
    p_od => TRUNC(SYSDATE), p_do => TRUNC(SYSDATE) + 3,
    o_booking_id => l_rez);
  DBMS_OUTPUT.PUT_LINE('Utworzono rezerwację nr ' || l_rez);

  BEGIN
    pkg_wypozyczenia.p_utworz_rezerwacje(6, 1, 2, TRUNC(SYSDATE) + 1, TRUNC(SYSDATE) + 2,
                                         o_booking_id => l_rez2);
    DBMS_OUTPUT.PUT_LINE('BŁĄD TESTU – podwójna rezerwacja');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_auto_niedostepne THEN
      DBMS_OUTPUT.PUT_LINE('OK, oczekiwany błąd: ' || SQLERRM);
  END;

  pkg_wypozyczenia.p_wydaj_auto(l_rez, p_employee_id => 2, p_metoda => 'CARD', p_karta_id => 1);
  SELECT b.booking_status || ' / auto: ' || v.vehicle_status
    INTO l_status
    FROM bookings b JOIN vehicles v ON v.vehicle_id = b.vehicle_id
   WHERE b.booking_id = l_rez;
  DBMS_OUTPUT.PUT_LINE('Po wydaniu: ' || l_status
                       || ', kaucja: ' || pkg_wypozyczenia.f_suma_wplat(l_rez, 'DEPOSIT'));

  pkg_wypozyczenia.p_przyjmij_zwrot(
    p_booking_id       => l_rez,
    p_przebieg_koncowy => 45800,
    p_metoda           => 'CARD',
    p_karta_id         => 1,
    p_szkody           => t_szkoda_tab(
                            t_szkoda('Pęknięta szyba czołowa', 'HIGH', 1500, 'Y'),
                            t_szkoda('Zarysowanie lusterka (sprzed wynajmu)', 'LOW', 150, 'N')),
    p_data_zwrotu      => TRUNC(SYSDATE) + 4,
    o_koszt            => l_koszt);

  DBMS_OUTPUT.PUT_LINE('Rozliczenie: ' || l_koszt.opis());

  FOR t IN (SELECT transaction_type, amount, payment_method
              FROM transactions WHERE booking_id = l_rez ORDER BY transaction_id)
  LOOP
    DBMS_OUTPUT.PUT_LINE('  transakcja: ' || RPAD(t.transaction_type, 11)
                         || TO_CHAR(t.amount, 'FM9999990.00') || ' zł (' || t.payment_method || ')');
  END LOOP;

  SELECT v.vehicle_status || ', przebieg ' || v.mileage
    INTO l_status FROM vehicles v WHERE v.vehicle_id = 1;
  DBMS_OUTPUT.PUT_LINE('Auto 1 po zwrocie: ' || l_status);

  FOR m IN (SELECT description FROM maintenance WHERE vehicle_id = 1 AND end_date IS NULL) LOOP
    DBMS_OUTPUT.PUT_LINE('  serwis: ' || m.description);
  END LOOP;
END;
/


/* ---------------------------------------------------------------------
   TEST 6 – P4 zwrot z drobną szkodą (kaucja pokrywa karę)
   Rezerwacja 6: auto 2 (Octavia 179 zł), 7 dni, kod JESIEN26 (-10%), kaucja 500 kartą 4.
   Oczekiwane: 7 x 179 = 1253.00 - 125.30 = 1127.70;
               kara 300 < kaucja 500 -> brak DAMAGE_FEE, REFUND 200.00; auto AVAILABLE
   --------------------------------------------------------------------- */
DECLARE
  l_koszt  t_koszt;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 6: zwrot – kaucja pokrywa karę ===');

  pkg_wypozyczenia.p_przyjmij_zwrot(
    p_booking_id       => 6,
    p_przebieg_koncowy => 31020,
    p_metoda           => 'CARD',
    p_karta_id         => 4,
    p_szkody           => t_szkoda_tab(t_szkoda('Wgniecenie drzwi kierowcy', 'LOW', 300, 'Y')),
    p_data_zwrotu      => DATE '2026-10-31',
    o_koszt            => l_koszt);

  DBMS_OUTPUT.PUT_LINE('Rozliczenie: ' || l_koszt.opis());
  FOR t IN (SELECT transaction_type, amount FROM transactions
             WHERE booking_id = 6 ORDER BY transaction_id)
  LOOP
    DBMS_OUTPUT.PUT_LINE('  transakcja: ' || RPAD(t.transaction_type, 11)
                         || TO_CHAR(t.amount, 'FM9999990.00') || ' zł');
  END LOOP;
END;
/


/* ---------------------------------------------------------------------
   TEST 7 – obsługa błędów (każdy blok powinien wypisać "OK, oczekiwany błąd")
   --------------------------------------------------------------------- */
DECLARE
  l_koszt  t_koszt;
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 7: błędy ===');

  -- a) wydanie auta z zakończonej rezerwacji -> -20005
  BEGIN
    pkg_wypozyczenia.p_wydaj_auto(1, 2, 'CASH');
    DBMS_OUTPUT.PUT_LINE('a) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_zly_status THEN
      DBMS_OUTPUT.PUT_LINE('a) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  -- b) przebieg mniejszy niż przy wydaniu (rez. 7: start 9800 km) -> -20007
  BEGIN
    pkg_wypozyczenia.p_przyjmij_zwrot(7, 9000, 'CASH', o_koszt => l_koszt);
    DBMS_OUTPUT.PUT_LINE('b) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_zly_przebieg THEN
      DBMS_OUTPUT.PUT_LINE('b) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  -- c) karta innego klienta (rez. 7 = klient 10, karta 1 = klient 5) -> -20008
  BEGIN
    pkg_wypozyczenia.p_przyjmij_zwrot(7, 10200, 'CARD', p_karta_id => 1, o_koszt => l_koszt);
    DBMS_OUTPUT.PUT_LINE('c) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_platnosc THEN
      DBMS_OUTPUT.PUT_LINE('c) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  -- d) nieprawidłowy stopień szkody -> -20009 (cały zwrot wycofany do savepointu)
  BEGIN
    pkg_wypozyczenia.p_przyjmij_zwrot(7, 10200, 'CASH',
      p_szkody => t_szkoda_tab(t_szkoda('Coś się stało', 'SUPER', 100, 'Y')),
      o_koszt  => l_koszt);
    DBMS_OUTPUT.PUT_LINE('d) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_zle_dane_szkody THEN
      DBMS_OUTPUT.PUT_LINE('d) OK, oczekiwany błąd: ' || SQLERRM);
  END;

  -- e) nieistniejąca rezerwacja -> -20006
  BEGIN
    pkg_wypozyczenia.p_anuluj_rezerwacje(99999);
    DBMS_OUTPUT.PUT_LINE('e) BŁĄD TESTU');
  EXCEPTION
    WHEN pkg_wypozyczenia.e_nie_znaleziono THEN
      DBMS_OUTPUT.PUT_LINE('e) OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 8 – P2 anulowanie rezerwacji 9 (wpłacona zaliczka 300 zł przelewem)
   Oczekiwane: status CANCELLED, REFUND 300.00 (TRANSFER); ponowne anulowanie = -20005
   --------------------------------------------------------------------- */
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 8: anulowanie ===');
  pkg_wypozyczenia.p_anuluj_rezerwacje(9);

  FOR t IN (SELECT transaction_type, amount, payment_method
              FROM transactions WHERE booking_id = 9 ORDER BY transaction_id)
  LOOP
    DBMS_OUTPUT.PUT_LINE('  transakcja: ' || RPAD(t.transaction_type, 11)
                         || TO_CHAR(t.amount, 'FM9999990.00') || ' zł (' || t.payment_method || ')');
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('Saldo netto rezerwacji 9: ' || pkg_wypozyczenia.f_suma_wplat(9));

  BEGIN
    pkg_wypozyczenia.p_anuluj_rezerwacje(9);
  EXCEPTION
    WHEN pkg_wypozyczenia.e_zly_status THEN
      DBMS_OUTPUT.PUT_LINE('OK, oczekiwany błąd: ' || SQLERRM);
  END;
END;
/


/* ---------------------------------------------------------------------
   TEST 9 – P5 historia klienta (kursor jawny)
   Oczekiwane: rezerwacje 1 i 5 + rezerwacja z testu 5
   --------------------------------------------------------------------- */
BEGIN
  DBMS_OUTPUT.PUT_LINE('=== TEST 9: historia klienta 5 ===');
  pkg_wypozyczenia.p_drukuj_historie_klienta(5);
END;
/


/* ---------------------------------------------------------------------
   TEST 10 – dziennik błędów (wpisy z testów 4, 5, 7, 8 zostają mimo ROLLBACK;
             funkcje nie logują – błąd z testu 3c trafia tylko do wywołującego)
   --------------------------------------------------------------------- */
SELECT log_id, TO_CHAR(log_date, 'HH24:MI:SS') AS czas, source_name, error_code, error_message
  FROM error_log
 ORDER BY log_id DESC
 FETCH FIRST 10 ROWS ONLY;


-- Przywrócenie danych przykładowych
ROLLBACK;
