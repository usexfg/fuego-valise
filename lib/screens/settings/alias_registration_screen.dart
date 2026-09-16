import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../bloc/wallet/wallet_cubit.dart';
import '../../services/fuego_rpc_service.dart';
import '../../utils/theme.dart';

class AliasRegistrationScreen extends StatefulWidget {
  const AliasRegistrationScreen({super.key});

  @override
  State<AliasRegistrationScreen> createState() => _AliasRegistrationScreenState();
}

class _AliasRegistrationScreenState extends State<AliasRegistrationScreen> {
  final TextEditingController _aliasController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;

  static final _validAlias = RegExp(r'^[a-z0-9&]{8}$');

  String? _validateAlias(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter an alias';
    }
    final alias = value.trim().toLowerCase();
    if (alias.length != 8) {
      return 'Alias must be exactly 8 characters';
    }
    if (!_validAlias.hasMatch(alias)) {
      return 'Only lowercase letters, digits, and & allowed';
    }
    return null;
  }

  Future<void> _registerAlias() async {
    final validationError = _validateAlias(_aliasController.text);
    if (validationError != null) {
      setState(() => _errorMessage = validationError);
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      setState(() => _isLoading = true);
      _errorMessage = null;
      _successMessage = null;

      // Alias registration uses a subaddress (derived from vault) instead of
      // master wallet address. Generate it first; if vault is locked, ask.
      final cubit = context.read<WalletCubit>();
      final sub = await cubit.createSubaddress(
        _aliasController.text.trim().toLowerCase(),
      );
      if (sub == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Unlock your wallet first to generate the alias subaddress';
        });
        return;
      }

      final rpcService = context.read<FuegoRPCService>();
      final txHash = await rpcService.registerAlias(
        _aliasController.text.trim().toLowerCase(),
        address: sub.address,
      );
      setState(() {
        _successMessage = 'Alias registration sent! Tx: $txHash';
      });
    } on FuegoRPCException catch (e) {
      setState(() {
        _errorMessage = e.message;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'An unknown error occurred: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Register Alias'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Aliases are exactly 8 characters using [a-z, 0-9, &]. '
              'They map to your wallet address and cost 1 XFG to register.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _aliasController,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9&]')),
                LengthLimitingTextInputFormatter(8),
              ],
              decoration: InputDecoration(
                labelText: 'Alias',
                hintText: 'myalias1',
                counterText: '${_aliasController.text.length}/8',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            if (_isLoading)
              const CircularProgressIndicator()
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _registerAlias,
                  child: const Text('Register Alias'),
                ),
              ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(_errorMessage!, style: const TextStyle(color: AppTheme.errorColor)),
            ],
            if (_successMessage != null) ...[
              const SizedBox(height: 16),
              Text(_successMessage!, style: const TextStyle(color: AppTheme.successColor)),
            ],
          ],
        ),
      ),
    );
  }
}
