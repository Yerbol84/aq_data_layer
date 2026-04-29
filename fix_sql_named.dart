/// Скрипт для автоматической замены execute() с parameters на Sql.named()
import 'dart:io';

void main() async {
  final file = File('lib/storage/postgres/postgres_vault_storage.dart');
  var content = await file.readAsString();

  // Паттерн: connection.execute( или session.execute(
  // за которым следует ''' или """
  // и потом parameters:

  // Заменяем connection.execute('''...''', parameters: на connection.execute(Sql.named('''...'''), parameters:
  content = content.replaceAllMapped(
    RegExp(
      r"(connection|session)\.execute\(\s*'''",
      multiLine: true,
    ),
    (match) => "${match.group(1)}.execute(Sql.named('''",
  );

  // Теперь нужно закрыть Sql.named() перед parameters:
  // Ищем ''', за которым идёт parameters:
  content = content.replaceAllMapped(
    RegExp(
      r"''',\s*parameters:",
      multiLine: true,
    ),
    (match) => "'''), parameters:",
  );

  await file.writeAsString(content);
  print('✓ Файл исправлен: ${file.path}');
  print('  Все execute() с parameters теперь используют Sql.named()');
}
