import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum AuthStatus { initial, initializing, authenticated, unauthenticated, error }

class AuthState extends Equatable {
  final AuthStatus status;
  final String? error;
  final String? address;

  const AuthState({this.status = AuthStatus.initial, this.error, this.address});

  AuthState copyWith({
    AuthStatus? status,
    String? error,
    bool clearError = false,
    String? address,
  }) => AuthState(
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    address: address ?? this.address,
  );

  @override
  List<Object?> get props => [status, error, address];

  @override
  String toString() => 'AuthState($status)';
}

/// Session auth for UI address only — vault unlock is handled by SecurityService.
class AuthCubit extends Cubit<AuthState> {
  static const _kAddress = 'fuego_address';
  static const _storage = FlutterSecureStorage();

  AuthCubit() : super(const AuthState());

  Future<void> initialize() async {
    emit(const AuthState(status: AuthStatus.initializing));
    try {
      final address = await _storage.read(key: _kAddress);
      if (address != null && address.isNotEmpty) {
        // Address known does NOT mean vault is unlocked
        emit(AuthState(status: AuthStatus.unauthenticated, address: address));
      } else {
        emit(const AuthState(status: AuthStatus.unauthenticated));
      }
    } catch (_) {
      emit(const AuthState(status: AuthStatus.unauthenticated));
    }
  }

  Future<void> signIn(String address) async {
    emit(const AuthState(status: AuthStatus.initializing));
    try {
      await _storage.write(key: _kAddress, value: address);
      emit(AuthState(status: AuthStatus.authenticated, address: address));
    } catch (e) {
      emit(
        AuthState(status: AuthStatus.error, error: 'Failed to persist session'),
      );
    }
  }

  Future<void> signOut() async {
    try {
      await _storage.delete(key: _kAddress);
    } catch (_) {}
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }
}
