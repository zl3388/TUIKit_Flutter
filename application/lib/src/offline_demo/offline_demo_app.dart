import 'dart:async';

import 'package:flutter/material.dart';

import 'bootstrap/offline_bootstrap.dart';
import 'presentation/offline_home.dart';
import 'presentation/offline_theme.dart';

class OfflineDemoApp extends StatefulWidget {
  const OfflineDemoApp({super.key});

  @override
  State<OfflineDemoApp> createState() => _OfflineDemoAppState();
}

class _OfflineDemoAppState extends State<OfflineDemoApp> {
  late Future<OfflineEnvironment> _environment;
  OfflineEnvironment? _resolvedEnvironment;

  @override
  void initState() {
    super.initState();
    _environment = _loadEnvironment();
  }

  Future<OfflineEnvironment> _loadEnvironment() async {
    final environment = await OfflineBootstrap.create();
    _resolvedEnvironment = environment;
    return environment;
  }

  void _retry() {
    setState(() {
      _environment = _loadEnvironment();
    });
  }

  @override
  void dispose() {
    final environment = _resolvedEnvironment;
    if (environment != null) {
      unawaited(environment.database.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '协作台',
      debugShowCheckedModeBanner: false,
      theme: OfflineTheme.light,
      home: FutureBuilder<OfflineEnvironment>(
        future: _environment,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return OfflineHome(environment: snapshot.requireData);
          }
          if (snapshot.hasError) {
            return _StartupError(error: snapshot.error, onRetry: _retry);
          }
          return const _StartupLoading();
        },
      ),
    );
  }
}

class _StartupLoading extends StatelessWidget {
  const _StartupLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub_outlined, size: 42, color: OfflineTheme.primary),
              SizedBox(height: 20),
              Text(
                '协作台',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 20),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.storage_rounded,
                    size: 48,
                    color: OfflineTheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '本地数据启动失败',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$error',
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF52616B),
                        ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
