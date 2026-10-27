# Wypożyczalnia samochodów – Oracle PL/SQL + APEX

Projekt zaliczeniowy z aplikacji bazodanowych: baza danych wypożyczalni samochodów
w Oracle (3NF), cztery pakiety PL/SQL oraz webowy interfejs w Oracle APEX.

## Kolejność uruchamiania (SQL Developer, F5 – Run Script)

| Plik | Zawartość |
|---|---|
| `sql/01_schemat_i_dane.sql` | 14 tabel, ograniczenia, indeksy, dane przykładowe |
| `sql/02_pkg_wypozyczenia.sql` | tabela `ERROR_LOG`, typy obiektowe i kolekcje, pakiet `PKG_WYPOZYCZENIA` |
| `sql/03_testy_pkg_wypozyczenia.sql` | testy pakietu (kończą się `ROLLBACK`) |
| `sql/04_pkg_flota.sql` | typy raportowe, pakiet `PKG_FLOTA` |
| `sql/05_testy_pkg_flota.sql` | testy pakietu (kończą się `ROLLBACK`) |
| `sql/06_pkg_klienci.sql` | tabela `LOGIN_LOG`, pakiet `PKG_KLIENCI`, hasła demonstracyjne |
| `sql/07_testy_pkg_klienci.sql` | testy pakietu (kończą się `ROLLBACK`) |
| `sql/08_pkg_analityka.sql` | typy pod wykresy, pakiet `PKG_ANALITYKA` |
| `sql/09_testy_pkg_analityka.sql` | testy pakietu (tylko odczyt) |

Każdy skrypt można uruchamiać ponownie – sam usuwa poprzednią wersję obiektów.

## Model danych

- **Słowniki:** `MAKES`, `MAINTENANCE_TYPES`, `PROMOTIONS`
- **Główne:** `USERS` (nadklasa) → `EMPLOYEES`, `CUSTOMERS`; `BRANCHES`, `VEHICLE_TYPES`, `VEHICLES`
- **Transakcyjne:** `BOOKINGS`, `PAYMENT_DETAILS`, `TRANSACTIONS`, `DAMAGES`, `MAINTENANCE`
- **Techniczne:** `ERROR_LOG`, `LOGIN_LOG`

Cykl życia rezerwacji: `RESERVED → ACTIVE → COMPLETED` lub `RESERVED → CANCELLED`.

## Pakiety

### PKG_WYPOZYCZENIA (rezerwacje, wydanie, zwrot)

| | Nazwa | Przypadek użycia |
|---|---|---|
| F1 | `f_czy_dostepne` | sprawdzenie dostępności auta w terminie |
| F2 | `f_oblicz_koszt` | UC02 – koszt z rabatem i spóźnieniem (obiekt `T_KOSZT`) |
| F3 | `f_dostepne_auta` | UC01 – lista wolnych aut (kolekcja `T_AUTO_DOSTEPNE_TAB`) |
| F4 | `f_czy_klient_uprawniony` | weryfikacja wieku i stażu prawa jazdy |
| F5 | `f_suma_wplat` | suma wpłat / saldo rezerwacji |
| P1 | `p_utworz_rezerwacje` | UC03 |
| P2 | `p_anuluj_rezerwacje` | UC04 |
| P3 | `p_wydaj_auto` | UC06 |
| P4 | `p_przyjmij_zwrot` | UC07 (szkody jako kolekcja `T_SZKODA_TAB`) |
| P5 | `p_drukuj_historie_klienta` | UC05 |

### PKG_FLOTA (serwis, flota, raporty)

| | Nazwa | Przypadek użycia |
|---|---|---|
| F1 | `f_km_do_przegladu` | km do przeglądu okresowego |
| F2 | `f_auta_do_przegladu` | UC12 – lista aut do przeglądu (kolekcja `T_PRZEGLAD_TAB`) |
| F3 | `f_raport_oddzialu` | UC13 – wynik finansowy oddziału (obiekt `T_RAPORT_ODDZIALU` z metodami) |
| F4 | `f_oblozenie_floty` | UC14 – obłożenie aut (kolekcja `T_OBLOZENIE_TAB`) |
| F5 | `f_koszt_serwisu` | koszty serwisu pojazdu |
| P1 | `p_skieruj_do_serwisu` | UC09 |
| P2 | `p_zakoncz_serwis` | UC10 |
| P3 | `p_przenies_auto` | UC11 |
| P4 | `p_dodaj_pojazd` | UC15 |
| P5 | `p_wycofaj_pojazd` | UC15 |
| P6 | `p_drukuj_raport_floty` | raport zbiorczy (zagnieżdżone kursory) |

Raporty przypisują przychody do oddziału, w którym auto jest **obecnie**
(rezerwacja nie przechowuje oddziału wydania) – świadome uproszczenie.

### PKG_KLIENCI (konta, logowanie, karty, lojalność, RODO)

| | Nazwa | Przypadek użycia |
|---|---|---|
| F1 | `f_zaloguj` | UC19 – funkcja uwierzytelniania APEX, blokada po 5 błędach / 15 min |
| F2 | `f_rola` | role do schematów autoryzacji APEX |
| F3 | `f_id_uzytkownika` | ID zalogowanego użytkownika |
| F4 | `f_poziom_lojalnosci` | UC22 – STANDARD / SREBRNY / ZLOTY / PLATYNOWY |
| F5 | `f_rabat_lojalnosciowy` | UC22 – 0 / 5 / 10 / 15 % |
| F6 | `f_profil_klienta` | UC22 – obiekt `T_PROFIL_KLIENTA` z metodą |
| F7 | `f_karty_wygasajace` | kolekcja `T_KARTA_TAB` |
| P1 | `p_zarejestruj_klienta` | UC18 |
| P2 | `p_ustaw_haslo` | reset hasła |
| P3 | `p_zmien_haslo` | UC20 |
| P4 | `p_dodaj_karte` | UC21 – algorytm Luhna, wykrycie typu karty |
| P5 | `p_usun_karte` | UC21 – ORA-02292 zamieniony na komunikat |
| P6 | `p_anonimizuj_klienta` | UC23 – kursor `FOR UPDATE` + `WHERE CURRENT OF` |

Hasła: sól + SHA-256 (`STANDARD_HASH`). Z karty zapisywane są tylko typ i 4 ostatnie cyfry.

### PKG_ANALITYKA (statystyki pod wykresy APEX)

| | Nazwa | Przypadek użycia |
|---|---|---|
| F1 | `f_ranking_modeli` | UC25 – `RANK()`, `RATIO_TO_REPORT()` |
| F2 | `f_top_klienci` | UC25 – `DENSE_RANK()` + poziom z `PKG_KLIENCI` |
| F3 | `f_przychod_miesieczny` | UC26 – `LAG()`, suma narastająca, generator miesięcy |
| F4 | `f_statystyki_dashboard` | UC24 – obiekt `T_STATYSTYKI` z metodą |
| F5 | `f_rozklad` | UC26 – dynamiczny SQL + `SYS_REFCURSOR` |
| P1 | `p_raport_miesieczny` | UC27 |
| P2 | `p_porownaj_oddzialy` | UC27 – korzysta z `PKG_FLOTA` |
| P3 | `p_raport_json` | UC29 – `JSON_OBJECT` / `JSON_ARRAYAGG` |
| P4 | `p_wykryj_anomalie` | UC28 |

## Konta demonstracyjne (APEX)

Hasło wszystkich kont z danych przykładowych: `Haslo123!`

| E-mail | Rola |
|---|---|
| tomasz.wojcik@wypozyczalnia.pl | ADMIN |
| anna.kowalska@wypozyczalnia.pl | MANAGER |
| piotr.nowak@wypozyczalnia.pl | CLERK |
| michal.kaminski@gmail.com | CUSTOMER |

## Reguły biznesowe

1. Klient: min. 21 lat, prawo jazdy od min. 1 roku.
2. Auto nie może mieć nakładających się rezerwacji ani być w serwisie / wycofane.
3. Kod rabatowy musi obowiązywać w dniu rozpoczęcia wynajmu.
4. Koszt = dni × stawka − rabat; każdy dzień spóźnienia według pełnej stawki.
5. Przy wydaniu pobierana jest kaucja 500 zł.
6. Anulować można tylko rezerwację `RESERVED` (wpłaty są zwracane).
7. Kara za szkodę z winy klienta = koszt naprawy: najpierw potrącana z kaucji,
   nadwyżka jako `DAMAGE_FEE`, niewykorzystana kaucja jako `REFUND`.
   Szkoda `HIGH` automatycznie kieruje auto do serwisu.
8. Przegląd wymagany po przekroczeniu `interval_km` od ostatniego przeglądu.

## Obsługa błędów

Własne wyjątki z komunikatami po polsku (wyświetlane w APEX),
`SAVEPOINT` w każdej procedurze oraz dziennik `ERROR_LOG` zapisywany w transakcji
autonomicznej.

| Kod | Wyjątek | Znaczenie |
|---|---|---|
| -20001 | `e_auto_niedostepne` | auto zajęte w terminie |
| -20002 | `e_zle_daty` | nieprawidłowe daty / okres |
| -20003 | `e_zly_kod_rabatowy` | kod nie istnieje lub nie obowiązuje |
| -20004 | `e_klient_nieuprawniony` | wiek < 21 lub prawo jazdy < 1 rok |
| -20005 | `e_zly_status` | zły status rezerwacji |
| -20006 | `e_nie_znaleziono` | brak rekordu |
| -20007 | `e_zly_przebieg` | przebieg mniejszy niż przy wydaniu |
| -20008 | `e_platnosc` | zła metoda płatności / karta |
| -20009 | `e_zle_dane_szkody` | nieprawidłowe dane szkody |
| -20010 | `e_zly_status_auta` | operacja niedozwolona w obecnym statusie auta |
| -20011 | `e_serwis` | serwis już otwarty / już zakończony |
| -20012 | `e_zle_dane` | nieprawidłowe dane (VIN, koszt, duplikat) |
| -20013 | `e_auto_zarezerwowane` | auto ma przyszłe rezerwacje |
| -20020 | `e_zle_dane` (KLIENCI) | błędne dane formularza |
| -20021 | `e_duplikat` | e-mail lub prawo jazdy już zarejestrowane |
| -20022 | `e_haslo` | hasło za słabe / błędne obecne hasło |
| -20023 | `e_konto_zablokowane` | zbyt wiele nieudanych logowań |
| -20024 | `e_karta` | zła karta (Luhn, ważność, duplikat, użyta) |
| -20025 | `e_klient_aktywny` | klient ma aktywne rezerwacje |
| -20030 | `e_zly_parametr` | zły parametr raportu |

## Dokumentacja

- `docs/erd.svg`, `docs/erd.png` – diagram ERD (wszystkie kolumny, PK/FK, 17 relacji)
- `docs/use_cases_wypozyczalnia.puml` – diagram przypadków użycia (PlantUML,
  do otwarcia np. na planttext.com)
- `tools/gen_erd.py` – generator ERD ze skryptu schematu:
  `python3 tools/gen_erd.py sql/01_schemat_i_dane.sql docs/erd.dot && dot -Tsvg docs/erd.dot -o docs/erd.svg`

## Źródło

Schemat bazowy oparty na
[tinyHiker/SQL_Rental_Database_Design](https://github.com/tinyHiker/SQL_Rental_Database_Design),
przebudowany i rozszerzony.
