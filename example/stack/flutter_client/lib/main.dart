import 'package:flutter/material.dart';
import 'package:dart_vault/dart_vault.dart';
import 'package:aq_schema/aq_schema.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vault Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _isConnected = false;
  String _status = 'Not connected';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      await initializeDataLayer(
        endpoint: 'http://localhost:8765',
        useBuffer: false,
      );
      setState(() {
        _isConnected = true;
        _status = 'Connected to ${IDataLayer.instance.endpoint}';
      });
    } catch (e) {
      setState(() {
        _status = 'Connection failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          title: const Text('Vault Client'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.folder), text: 'Projects'),
              Tab(icon: Icon(Icons.play_arrow), text: 'Runs'),
              Tab(icon: Icon(Icons.description), text: 'Documents'),
            ],
          ),
        ),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              color: _isConnected ? Colors.green[100] : Colors.red[100],
              child: Row(
                children: [
                  Icon(
                    _isConnected ? Icons.check_circle : Icons.error,
                    color: _isConnected ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_status)),
                ],
              ),
            ),
            Expanded(
              child: _isConnected
                  ? const TabBarView(
                      children: [
                        ProjectsTab(),
                        RunsTab(),
                        DocumentsTab(),
                      ],
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }
}

// Projects Tab - Direct Storage
class ProjectsTab extends StatefulWidget {
  const ProjectsTab({super.key});

  @override
  State<ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<ProjectsTab> {
  List<AqStudioProject> _projects = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _loading = true);
    try {
      final repo = IDataLayer.instance.direct<AqStudioProject>(
        collection: AqStudioProject.kCollection,
        fromMap: AqStudioProject.fromMap,
      );
      final projects = await repo.findAll();
      setState(() {
        _projects = projects;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _createProject() async {
    final nameController = TextEditingController();
    final typeController = TextEditingController(text: 'flutter');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Project Name'),
            ),
            TextField(
              controller: typeController,
              decoration: const InputDecoration(labelText: 'Project Type'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.isNotEmpty) {
      try {
        final repo = IDataLayer.instance.direct<AqStudioProject>(
          collection: AqStudioProject.kCollection,
          fromMap: AqStudioProject.fromMap,
        );

        final project = AqStudioProject.create(
          id: 'proj-${DateTime.now().millisecondsSinceEpoch}',
          tenantId: IDataLayer.instance.tenantId,
          ownerId: 'user-001',
          name: nameController.text,
          projectType: typeController.text,
        );

        await repo.save(project);
        await _loadProjects();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Project created')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteProject(AqStudioProject project) async {
    try {
      final repo = IDataLayer.instance.direct<AqStudioProject>(
        collection: AqStudioProject.kCollection,
        fromMap: AqStudioProject.fromMap,
      );
      await repo.delete(project.id);
      await _loadProjects();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Text('Projects: ${_projects.length}',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _createProject,
                icon: const Icon(Icons.add),
                label: const Text('Create'),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _loadProjects,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: _projects.isEmpty
              ? const Center(child: Text('No projects'))
              : ListView.builder(
                  itemCount: _projects.length,
                  itemBuilder: (context, index) {
                    final project = _projects[index];
                    return ListTile(
                      leading: const Icon(Icons.folder),
                      title: Text(project.name),
                      subtitle: Text('Type: ${project.projectType}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _deleteProject(project),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// Runs Tab - Logged Storage
class RunsTab extends StatefulWidget {
  const RunsTab({super.key});

  @override
  State<RunsTab> createState() => _RunsTabState();
}

class _RunsTabState extends State<RunsTab> {
  List<WorkflowRun> _runs = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadRuns();
  }

  Future<void> _loadRuns() async {
    setState(() => _loading = true);
    try {
      final repo = IDataLayer.instance.logged<WorkflowRun>(
        collection: WorkflowRun.kCollection,
        fromMap: WorkflowRun.fromMap,
      );
      final runs = await repo.findAll();
      setState(() {
        _runs = runs;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _createRun() async {
    try {
      final repo = IDataLayer.instance.logged<WorkflowRun>(
        collection: WorkflowRun.kCollection,
        fromMap: WorkflowRun.fromMap,
      );

      final run = WorkflowRun(
        id: 'run-${DateTime.now().millisecondsSinceEpoch}',
        projectId: 'proj-001',
        blueprintId: 'blueprint-001',
        graphSnapshot: <String, dynamic>{},
        status: WorkflowRunStatus.running,
        logsJson: '[]',
        contextJson: '{}',
        createdAt: DateTime.now(),
      );

      await repo.save(run, actorId: 'user-001');
      await _loadRuns();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Run created')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _updateStatus(WorkflowRun run, WorkflowRunStatus status) async {
    try {
      final repo = IDataLayer.instance.logged<WorkflowRun>(
        collection: WorkflowRun.kCollection,
        fromMap: WorkflowRun.fromMap,
      );

      final updated = run.copyWith(status: status);
      await repo.save(updated, actorId: 'user-001');
      await _loadRuns();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Status updated to ${status.value}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _showAuditLog(WorkflowRun run) async {
    try {
      final repo = IDataLayer.instance.logged<WorkflowRun>(
        collection: WorkflowRun.kCollection,
        fromMap: WorkflowRun.fromMap,
      );

      final logs = await repo.getHistory(run.id);

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Audit Log: ${run.id}'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final log = logs[index];
                  return ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(log.operation.toString()),
                    subtitle: Text(log.changedAt.toString()),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  IconData _getStatusIcon(WorkflowRunStatus status) {
    switch (status) {
      case WorkflowRunStatus.running:
        return Icons.play_arrow;
      case WorkflowRunStatus.suspended:
        return Icons.pause;
      case WorkflowRunStatus.completed:
        return Icons.check_circle;
      case WorkflowRunStatus.failed:
        return Icons.error;
      case WorkflowRunStatus.cancelled:
        return Icons.cancel;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Text('Runs: ${_runs.length}',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _createRun,
                icon: const Icon(Icons.add),
                label: const Text('Create'),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _loadRuns,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: _runs.isEmpty
              ? const Center(child: Text('No runs'))
              : ListView.builder(
                  itemCount: _runs.length,
                  itemBuilder: (context, index) {
                    final run = _runs[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: ListTile(
                        leading: Icon(_getStatusIcon(run.status)),
                        title: Text(run.id),
                        subtitle: Text('Status: ${run.status.value}'),
                        trailing: PopupMenuButton<WorkflowRunStatus>(
                          onSelected: (status) => _updateStatus(run, status),
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: WorkflowRunStatus.running,
                              child: Text('Running'),
                            ),
                            const PopupMenuItem(
                              value: WorkflowRunStatus.suspended,
                              child: Text('Suspended'),
                            ),
                            const PopupMenuItem(
                              value: WorkflowRunStatus.completed,
                              child: Text('Completed'),
                            ),
                            const PopupMenuItem(
                              value: WorkflowRunStatus.failed,
                              child: Text('Failed'),
                            ),
                          ],
                        ),
                        onTap: () => _showAuditLog(run),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// Documents Tab - Direct Storage with Migrations
class DocumentsTab extends StatefulWidget {
  const DocumentsTab({super.key});

  @override
  State<DocumentsTab> createState() => _DocumentsTabState();
}

class _DocumentsTabState extends State<DocumentsTab> {
  List<TestDocumentV1> _documents = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadDocuments();
  }

  Future<void> _loadDocuments() async {
    setState(() => _loading = true);
    try {
      final repo = IDataLayer.instance.direct<TestDocumentV1>(
        collection: TestDocumentV1.kCollection,
        fromMap: TestDocumentV1.fromMap,
      );
      final docs = await repo.findAll();
      setState(() {
        _documents = docs;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _createDocument() async {
    final titleController = TextEditingController();
    final contentController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Document'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: contentController,
              decoration: const InputDecoration(labelText: 'Content'),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true && titleController.text.isNotEmpty) {
      try {
        final repo = IDataLayer.instance.direct<TestDocumentV1>(
          collection: TestDocumentV1.kCollection,
          fromMap: TestDocumentV1.fromMap,
        );

        final doc = TestDocumentV1(
          id: 'doc-${DateTime.now().millisecondsSinceEpoch}',
          tenantId: IDataLayer.instance.tenantId,
          title: titleController.text,
          content: contentController.text,
        );

        await repo.save(doc);
        await _loadDocuments();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Document created')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }

  Future<void> _deleteDocument(TestDocumentV1 doc) async {
    try {
      final repo = IDataLayer.instance.direct<TestDocumentV1>(
        collection: TestDocumentV1.kCollection,
        fromMap: TestDocumentV1.fromMap,
      );
      await repo.delete(doc.id);
      await _loadDocuments();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Text('Documents: ${_documents.length}',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _createDocument,
                icon: const Icon(Icons.add),
                label: const Text('Create'),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _loadDocuments,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: _documents.isEmpty
              ? const Center(child: Text('No documents'))
              : ListView.builder(
                  itemCount: _documents.length,
                  itemBuilder: (context, index) {
                    final doc = _documents[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: ListTile(
                        leading: const Icon(Icons.description),
                        title: Text(doc.title),
                        subtitle: Text(
                          doc.content,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete),
                          onPressed: () => _deleteDocument(doc),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
