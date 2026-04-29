/// Комплексный скрипт для замены именованных параметров на позиционные
/// во всем файле postgres_vault_storage.dart
import 'dart:io';

void main() async {
  final file = File('lib/storage/postgres/postgres_vault_storage.dart');
  var content = await file.readAsString();

  // Убираем все Sql.named(
  content = content.replaceAll(RegExp(r'Sql\.named\('), '');

  // Убираем закрывающие скобки перед ), parameters:
  content = content.replaceAll(RegExp(r"'''\),\s*parameters:"), "''', parameters:");

  // Заменяем именованные параметры на позиционные в SQL
  // @id → \$1, @tenant_id → \$2, @data → \$3
  content = content.replaceAll('@id', r'$1');
  content = content.replaceAll('@tenant_id', r'$2');
  content = content.replaceAll('@data', r'$3');
  content = content.replaceAll('@ids', r'$1');

  // Заменяем Map параметры на List
  // parameters: {'id': id, 'tenant_id': tenantId} → parameters: [id, tenantId]
  content = content.replaceAllMapped(
    RegExp(r"parameters:\s*\{\s*'id':\s*id,\s*'tenant_id':\s*tenantId\s*\}", multiLine: true),
    (match) => 'parameters: [id, tenantId]',
  );

  content = content.replaceAllMapped(
    RegExp(r"parameters:\s*\{\s*'id':\s*id,\s*'tenant_id':\s*tenantId,\s*'data':\s*data\s*\}", multiLine: true),
    (match) => 'parameters: [id, tenantId, data]',
  );

  content = content.replaceAllMapped(
    RegExp(r"parameters:\s*\{\s*'ids':\s*ids,\s*'tenant_id':\s*tenantId,\s*'data':\s*dataList\s*\}", multiLine: true),
    (match) => 'parameters: [ids, tenantId, dataList]',
  );

  content = content.replaceAllMapped(
    RegExp(r"parameters:\s*\{\s*'tenant_id':\s*tenantId\s*\}", multiLine: true),
    (match) => 'parameters: [tenantId]',
  );

  await file.writeAsString(content);
  print('✓ Файл исправлен: ${file.path}');
  print('  - Удалены все Sql.named()');
  print('  - Заменены @id, @tenant_id, @data на \$1, \$2, \$3');
  print('  - Заменены Map параметры на List');
}
