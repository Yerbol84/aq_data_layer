/// Скрипт для удаления всех Sql.named() и замены на позиционные параметры
import 'dart:io';

void main() async {
  final file = File('lib/storage/postgres/postgres_vault_storage.dart');
  var content = await file.readAsString();

  // Убираем Sql.named( и соответствующую закрывающую скобку
  // Паттерн: Sql.named('''...'''), parameters: {...}
  // Заменяем на: '''...''', parameters: [...]

  // Шаг 1: Убираем Sql.named(
  content = content.replaceAll('Sql.named(', '');

  // Шаг 2: Убираем закрывающую скобку перед ), parameters:
  content = content.replaceAllMapped(
    RegExp(r"'''\),\s*parameters:", multiLine: true),
    (match) => "''', parameters:",
  );

  await file.writeAsString(content);
  print('✓ Файл исправлен: ${file.path}');
  print('  Все Sql.named() удалены');
  print('  ⚠️  ВНИМАНИЕ: Нужно вручную заменить именованные параметры на позиционные!');
  print('     @id, @tenant_id → \$1, \$2');
  print('     parameters: {\'id\': id, \'tenant_id\': tenantId} → parameters: [id, tenantId]');
}
