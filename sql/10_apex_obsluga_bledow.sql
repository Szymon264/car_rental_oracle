/* =====================================================================
   OBSŁUGA BŁĘDÓW APLIKACJI APEX
   Uruchamiać TYLKO w bazie z Oracle APEX (korzysta z pakietu APEX_ERROR).
   Wymaga: 02_pkg_wypozyczenia.sql (P_LOGUJ_BLAD)

   Podpięcie: Shared Components -> Application Definition (Edit Application
   Properties) -> Error Handling -> Error Handling Function:
       f_apex_obsluga_bledow

   Działanie:
   - błędy biznesowe z pakietów (RAISE_APPLICATION_ERROR -20000..-20999):
     użytkownik widzi sam polski komunikat, bez "ORA-200xx:" i stosu wywołań
     (procedury pakietów same zapisały już błąd w ERROR_LOG);
   - naruszenia ograniczeń (klucze, CHECK, UNIQUE, NOT NULL): czytelny komunikat
     zamiast technicznego, zapis do ERROR_LOG;
   - inne nieoczekiwane błędy bazy: ogólny komunikat + zapis do ERROR_LOG;
   - błędy wewnętrzne APEX (np. wygaśnięcie sesji) zostają bez zmian.
   ===================================================================== */
CREATE OR REPLACE FUNCTION f_apex_obsluga_bledow (
  p_error IN apex_error.t_error
) RETURN apex_error.t_error_result IS
  l_wynik  apex_error.t_error_result;
BEGIN
  l_wynik := apex_error.init_error_result(p_error => p_error);

  IF p_error.is_internal_error THEN
    RETURN l_wynik;
  END IF;

  IF p_error.ora_sqlcode BETWEEN -20999 AND -20000 THEN
    -- nasze wyjątki: tylko treść komunikatu
    l_wynik.message         := apex_error.get_first_ora_error_text(p_error => p_error);
    l_wynik.additional_info := NULL;

  ELSIF p_error.ora_sqlcode IN (-1, -2290, -2291, -2292, -1400) THEN
    p_loguj_blad('APEX', p_error.ora_sqlcode, p_error.ora_sqlerrm, p_error.error_backtrace);
    l_wynik.message := CASE p_error.ora_sqlcode
      WHEN -1    THEN 'Taki rekord już istnieje (powtórzona wartość unikalna).'
      WHEN -2290 THEN 'Wprowadzone dane nie spełniają reguł poprawności.'
      WHEN -2291 THEN 'Wskazany powiązany rekord nie istnieje.'
      WHEN -2292 THEN 'Nie można usunąć rekordu, bo korzystają z niego inne dane.'
      WHEN -1400 THEN 'Nie wypełniono wymaganego pola.'
    END;
    l_wynik.additional_info := NULL;

  ELSIF p_error.ora_sqlcode IS NOT NULL THEN
    p_loguj_blad('APEX', p_error.ora_sqlcode, p_error.ora_sqlerrm, p_error.error_backtrace);
    l_wynik.message         := 'Wystąpił nieoczekiwany błąd. Szczegóły zapisano w dzienniku błędów.';
    l_wynik.additional_info := NULL;
  END IF;

  RETURN l_wynik;
END f_apex_obsluga_bledow;
/
