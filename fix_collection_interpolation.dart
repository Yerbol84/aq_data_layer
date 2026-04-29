/// Скрипт для замены $collection на ${collection} в SQL запросах
import 'dart:io';

void main() async {
  final file = File('lib/storage/postgres/postgres_vault_storage.dart');
  var content = await file.readAsString();

  // Заменяем $collection на ${collection} внутри SQL строк
  content = content.replaceAll(r'$collection', r'${collection}');

  // Заменяем $tableName на ${tableName} если есть
  content = content.replaceAll(r'$tableName', r'${tableName}');

  await file.writeAsString(content);
  print('✓ Файл исправлен: ${file.path}');
  print('  Все \$collection заменены на \${collection}');
}
