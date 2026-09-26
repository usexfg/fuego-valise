import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/chain_registry.g.dart';
import '../../services/evm_account_service.dart';
import '../../utils/theme.dart';

class CreateEvmAccountScreen extends StatefulWidget {
  const CreateEvmAccountScreen({super.key});

  @override
  State<CreateEvmAccountScreen> createState() =>
      _CreateEvmAccountScreenState();
}

class _CreateEvmAccountScreenState extends State<CreateEvmAccountScreen> {
  final _nameController = TextEditingController();
  final _privateKeyController = TextEditingController();
  final _evmChains = kChains.where((chain) => chain.family == 'evm').toList();
  late final EvmAccountService _accountService;
  String _chainKey = 'eth';
  bool _importMode = false;
  bool _isSaving = false;
  String? _errorMessage;
  EvmAccountCredentials? _created;

  @override
  void initState() {
    super.initState();
    _accountService = context.read<EvmAccountService>();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _privateKeyController.dispose();
    super.dispose();
  }

  Future<void> _saveAccount() async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final result = _importMode
          ? await _accountService.importExisting(
              name: _nameController.text,
              chainKey: _chainKey,
              privateKeyHex: _privateKeyController.text,
            )
          : await _accountService.createNew(
              name: _nameController.text,
              chainKey: _chainKey,
            );
      if (!mounted) return;
      setState(() {
        _created = result;
        _isSaving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = _friendlyError(error);
      });
    }
  }

  Future<void> _copyPrivateKey() async {
    final key = _created?.privateKeyHex;
    if (key == null) return;
    await Clipboard.setData(ClipboardData(text: key));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Private key copied. Store it securely.')),
    );
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    return message.contains('Invalid EVM private key') ||
            message.contains('64 hexadecimal')
        ? 'Enter a valid 64-character hexadecimal EVM private key.'
        : message.replaceFirst('Exception: ', '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_created == null ? 'New EVM Wallet' : 'Back Up Wallet')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _created == null ? _buildForm() : _buildBackup(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'One account, every EVM chain',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        const Text(
          'The selected chain is your starting view. The same address works on every EVM network in the registry.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _modeButton(
                label: 'Create new',
                selected: !_importMode,
                onPressed: () => setState(() {
                  _importMode = false;
                  _errorMessage = null;
                }),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _modeButton(
                label: 'Import key',
                selected: _importMode,
                onPressed: () => setState(() {
                  _importMode = true;
                  _errorMessage = null;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Wallet name',
            hintText: 'e.g. Treasury account',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: _chainKey,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Starting chain',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final chain in _evmChains)
              DropdownMenuItem(
                value: chain.key,
                child: Text('${chain.name} (${chain.ticker})'),
              ),
          ],
          onChanged: _isSaving
              ? null
              : (value) {
                  if (value != null) setState(() => _chainKey = value);
                },
        ),
        if (_importMode) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _privateKeyController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Private key',
              hintText: '64 hexadecimal characters',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMessage!,
            style: const TextStyle(color: AppTheme.errorColor),
          ),
        ],
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _isSaving ? null : _saveAccount,
          icon: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_importMode ? Icons.download : Icons.add),
          label: Text(_isSaving
              ? 'Saving...'
              : (_importMode ? 'Import and save' : 'Generate and save')),
        ),
        const SizedBox(height: 12),
        const Text(
          'Keys are stored in platform secure storage. Never send a private key to anyone.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _modeButton({
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton(
      onPressed: _isSaving ? null : onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? AppTheme.primaryColor.withValues(alpha: 0.14)
            : Colors.transparent,
        side: BorderSide(
          color: selected ? AppTheme.primaryColor : AppTheme.textMuted,
        ),
      ),
      child: Text(label),
    );
  }

  Widget _buildBackup() {
    final created = _created!;
    final chain = kChainByKey[created.account.chainKey];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.warning_amber_rounded,
            color: AppTheme.warningColor, size: 44),
        const SizedBox(height: 12),
        const Text(
          'Save this private key now',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'It will not be shown again by this screen. Anyone with it can spend this account.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 24),
        _detailRow('Wallet', created.account.name),
        _detailRow('Network view', chain?.name ?? created.account.chainKey),
        _detailRow('Address', created.account.address),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.cardColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.35)),
          ),
          child: SelectableText(
            created.privateKeyHex,
            style: AppTheme.numericStyle(fontSize: 13),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _copyPrivateKey,
          icon: const Icon(Icons.copy),
          label: const Text('Copy private key'),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Saved securely - continue'),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(label, style: const TextStyle(color: AppTheme.textMuted)),
          ),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(color: AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}
