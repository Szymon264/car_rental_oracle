# Wypożyczalnia samochodów – Oracle PL/SQL + APEX

Projekt zaliczeniowy z aplikacji bazodanowych: baza danych wypożyczalni samochodów
w Oracle (3NF), dwa pakiety PL/SQL oraz webowy interfejs w Oracle APEX.

## Kolejność uruchamiania (SQL Developer, F5 – Run Script)

| Plik | Zawartość |
|---|---|
| `sql/01_schemat_i_dane.sql` | 14 tabel, ograniczenia, indeksy, dane przykładowe |
| `sql/02_pkg_wypozyczenia.sql` | tabela `ERROR_LOG`, typy obiektowe i kolekcje, pakiet `PKG_WYPOZYCZENIA` |
| `sql/03_testy_pkg_wypozyczenia.sql` | testy pakietu (kończą się `ROLLBACK`) |

Każdy skrypt można uruchamiać ponownie – sam usuwa poprzednią wersję obiektów.

## Model danych

- **Słowniki:** `MAKES`, `MAINTENANCE_TYPES`, `PROMOTIONS`
- **Główne:** `USERS` (nadklasa) → `EMPLOYEES`, `CUSTOMERS`; `BRANCHES`, `VEHICLE_TYPES`, `VEHICLES`
- **Transakcyjne:** `BOOKINGS`, `PAYMENT_DETAILS`, `TRANSACTIONS`, `DAMAGES`, `MAINTENANCE`
- **Techniczne:** `ERROR_LOG`

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

W przygotowaniu.

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

Własne wyjątki `-20001…-20009` z komunikatami po polsku (wyświetlane w APEX),
`SAVEPOINT` w każdej procedurze oraz dziennik `ERROR_LOG` zapisywany w transakcji
autonomicznej.

## Dokumentacja

- `docs/use_cases_wypozyczalnia.puml` – diagram przypadków użycia (PlantUML,
  do otwarcia np. na planttext.com)

## Źródło

Schemat bazowy oparty na
[tinyHiker/SQL_Rental_Database_Design](https://github.com/tinyHiker/SQL_Rental_Database_Design),
przebudowany i rozszerzony.
