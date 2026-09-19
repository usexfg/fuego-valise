// Widget for inputting mnemonic seed phrase
import 'package:flutter/material.dart';
import '../utils/theme.dart';

class MnemonicInput extends StatefulWidget {
  final Function(String)? onMnemonicChanged;
  final bool validateOnInput;
  final int expectedWordCount;

  const MnemonicInput({
    Key? key,
    this.onMnemonicChanged,
    this.validateOnInput = true,
    this.expectedWordCount = 12,
  }) : super(key: key);

  @override
  State<MnemonicInput> createState() => _MnemonicInputState();
}

class _MnemonicInputState extends State<MnemonicInput> {
  final List<TextEditingController> _controllers = [];
  final List<FocusNode> _focusNodes = [];
  bool _isValid = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
  }

  void _initializeControllers() {
    for (int i = 0; i < widget.expectedWordCount; i++) {
      _controllers.add(TextEditingController());
      _focusNodes.add(FocusNode());

      _controllers[i].addListener(() {
        _onWordChanged(i);
      });
    }
  }

  void _onWordChanged(int index) {
    final text = _controllers[index].text.trim().toLowerCase();

    if (text.isEmpty) {
      setState(() {
        _isValid = false;
      });
      return;
    }

    // Move focus to next field if word is complete
    if (text.contains(' ') && index < widget.expectedWordCount - 1) {
      final words = text.split(' ');
      _controllers[index].text = words.first;
      if (words.length > 1) {
        _controllers[index + 1].text = words.skip(1).join(' ');
        _focusNodes[index + 1].requestFocus();
      }
    }

    _validateMnemonic();
  }

  void _validateMnemonic() {
    final words = _controllers
        .map((c) => c.text.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList();

    if (words.length == widget.expectedWordCount) {
      setState(() {
        _isValid = true;
        _errorMessage = null;
      });
      widget.onMnemonicChanged?.call(words.join(' '));
    } else {
      setState(() {
        _isValid = false;
        _errorMessage = null;
      });
    }
  }

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
    for (var focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  String getMnemonic() {
    return _controllers
        .map((c) => c.text.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Enter your ${widget.expectedWordCount}-word seed phrase',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Enter each word in order',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(widget.expectedWordCount, (index) {
            return SizedBox(
              width: (MediaQuery.of(context).size.width - 40) / 3,
              child: TextField(
                controller: _controllers[index],
                focusNode: _focusNodes[index],
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textPrimary,
                ),
                decoration: InputDecoration(
                  labelText: '${index + 1}',
                  labelStyle: TextStyle(
                    fontSize: 10,
                    color: AppTheme.textSecondary,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: AppTheme.primaryColor.withOpacity(0.3),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: AppTheme.primaryColor,
                      width: 2,
                    ),
                  ),
                  filled: true,
                  fillColor: AppTheme.backgroundColor.withOpacity(0.5),
                ),
                textInputAction: index < widget.expectedWordCount - 1
                    ? TextInputAction.next
                    : TextInputAction.done,
                onSubmitted: (value) {
                  if (index < widget.expectedWordCount - 1) {
                    _focusNodes[index + 1].requestFocus();
                  }
                },
              ),
            );
          }),
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 16, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        if (_isValid && _errorMessage == null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 16, color: Colors.green),
                const SizedBox(width: 8),
                Text(
                  'Valid seed phrase',
                  style: const TextStyle(color: Colors.green, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
