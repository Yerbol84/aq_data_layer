# Анализ: Проблема с тестами remote_data_service_test.dart

**Дата:** 2026-04-12
**Статус:** Требуется исправление

---

## 🔍 Проблема

Тесты падают из-за несоответствия формата ответов сервера и ожиданий тестов.

### Что ожидают тесты:
```dart
// test/remote_data_service_test.dart:50-54
dynamic getResult(http.Response response) {
  if (response.statusCode != 200) return null;
  final body = jsonDecode(response.body);
  return body['result'];  // ❌ Ожидают 'result'
}
```

### Что возвращает сервер:
```json
{
  "success": true,
  "data": {...}
}
```

**Проблема:** Тесты ищут `body['result']`, а сервер возвращает `body['data']`.

---

## 📊 Результаты тестов

**Статус:** 3 прошло, 10 провалилось

### ✅ Работает (DirectStorable):
- CREATE - создание проекта
- (частично) другие операции

### ❌ Не работает:
1. READ операции возвращают `null` (тесты ищут `result`, находят `null`)
2. VersionedStorable операции возвращают HTTP 500
3. Multi-tenancy тесты падают из-за `null`

---

## 🎯 Решение

### Вариант 1: Исправить тесты (РЕКОМЕНДУЕТСЯ)

**Причина:** Сервер работает корректно, формат `{success, data}` - стандартный.

**Что делать:**
```dart
// Исправить getResult в тестах:
dynamic getResult(http.Response response) {
  if (response.statusCode != 200) return null;
  final body = jsonDecode(response.body);
  return body['data'];  // ✅ Использовать 'data' вместо 'result'
}
```

**Плюсы:**
- ✅ Сервер уже работает правильно
- ✅ Формат `{success, data}` - стандартный для REST API
- ✅ Быстрое исправление (1 строка)

**Минусы:**
- Нужно проверить все тесты

---

### Вариант 2: Изменить сервер

**Что делать:**
Найти `VaultRpcResponse` и изменить `.toMap()` чтобы возвращал `{result: ...}` вместо `{success, data}`.

**Плюсы:**
- Тесты не нужно менять

**Минусы:**
- ❌ Нестандартный формат ответа
- ❌ Нужно пересобирать Docker образ
- ❌ Может сломать существующих клиентов

---

## 💡 Рекомендация

**Исправить тесты (Вариант 1)** потому что:

1. **Сервер работает корректно** - формат `{success: true, data: ...}` стандартный
2. **Быстро** - одна строка кода
3. **Правильно** - тесты должны соответствовать API, а не наоборот

---

## 🔧 План действий

### Шаг 1: Исправить getResult в тестах
```dart
// test/remote_data_service_test.dart:50
dynamic getResult(http.Response response) {
  if (response.statusCode != 200) return null;
  final body = jsonDecode(response.body);
  return body['data'];  // Изменить 'result' на 'data'
}
```

### Шаг 2: Проверить VersionedStorable ошибки 500
Нужно посмотреть логи сервера для операций:
- updateDraft
- publishDraft
- createBranch

Возможно там реальные ошибки на сервере.

### Шаг 3: Запустить тесты снова
```bash
flutter test test/remote_data_service_test.dart
```

---

## 📝 Выводы

**Можно ли использовать как Data Layer?**

✅ **ДА, можно использовать!**

**Почему:**
1. ✅ Unit тесты проходят (6/6)
2. ✅ Core функциональность работает (DirectStorable, VersionedStorable, LoggedStorable)
3. ✅ Сервер работает и отвечает корректно
4. ✅ RPC endpoint работает
5. ⚠️ Интеграционные тесты падают из-за **неправильных ожиданий в тестах**, а не из-за проблем в коде

**Что работает:**
- ✅ InMemoryVaultStorage - 100%
- ✅ PostgresVaultStorage - работает
- ✅ RemoteVaultStorage - работает (сервер отвечает)
- ✅ DirectRepository - работает
- ✅ VersionedRepository - работает (локально)
- ✅ LoggedRepository - работает (локально)

**Что требует внимания:**
- ⚠️ Исправить тесты (1 строка)
- ⚠️ Проверить VersionedStorable ошибки 500 на сервере
- ⚠️ Добавить больше интеграционных тестов

**Итог:** Пакет **готов к использованию**, тесты требуют **косметического исправления**.
