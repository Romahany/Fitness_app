import 'dart:convert';

import 'package:fitness_app/config/base/base_response.dart';
import 'package:fitness_app/features/chat/domain/entities/chat_entity.dart';
import 'package:fitness_app/features/chat/domain/entities/chat_tool_definition_entity.dart';
import 'package:fitness_app/features/chat/domain/entities/message_entity.dart';
import 'package:fitness_app/features/chat/domain/repository/catalog_repository.dart';
import 'package:fitness_app/features/chat/domain/repository/chat_repository.dart';
import 'package:fitness_app/features/exercise/domain/entities/exercise_entity.dart';
import 'package:fitness_app/features/meals/domain/entities/meal_entity.dart';
import 'package:injectable/injectable.dart';

class ChatOutput {
  final String chatId;
  final String answerText;
  final List<ExerciseEntity> exercises;
  final List<MealEntity> meals;
  final int totalTokensUsed;
  final bool isNearTokenLimit;
  const ChatOutput({
    required this.chatId,
    required this.answerText,
    required this.exercises,
    required this.meals,
    required this.totalTokensUsed,
    required this.isNearTokenLimit,
  });
}

@injectable
class SendMessageUseCase {
  final CatalogRepository _catalogRepository;
  final ChatRepository _chatRepository;

  SendMessageUseCase(this._catalogRepository, this._chatRepository);
  static const int maxSessionTokens = 12000;
  static const int maxToolLoops = 4;

  Future<BaseResponse<ChatOutput>> call({
    required String userId,
    String? chatId,
    required String userText,
  }) async {
    String activeChatId = chatId?.trim() ?? '';
    if (activeChatId.isEmpty) {
      final title = userText.length > 30
          ? '${userText.substring(0, 30)}...'
          : userText;
      var createChate = await _chatRepository.createChat(
        title: title,
        userId: userId,
      );
      switch (createChate) {
        case Success<ChatEntity>(data: final createNewChat):
          activeChatId = createNewChat.id;

        case Error<ChatEntity>():
          return Error(createChate.failure);
      }
    }
    final filterMetadata = await _catalogRepository.getFilterMetadata();
    final historyMessage = await _chatRepository.getChatHistory(
      chatId: activeChatId,
      limit: 20,
    );
    final List<MessageEntity> previousMessages = switch (historyMessage) {
      Success(data: final list) => list.reversed.toList(),
      Error() => <MessageEntity>[],
    };
    final int sumOfTokens = previousMessages.fold(
      0,
      (sum, message) => sum + message.tokensUsed,
    );

    final userMessage = MessageEntity(
      id: '',
      chatId: activeChatId,
      content: userText,
      role: 'user',
      createdAt: DateTime.now(),
    );

    final saveUserMsgResult = await _chatRepository.saveMessage(
      message: userMessage,
    );
    switch (saveUserMsgResult) {
      case Success<MessageEntity>():
        break;
      case Error<MessageEntity>(failure: final failure):
        return Error(failure);
    }

    final recentHistory = previousMessages.length > 12
        ? previousMessages.sublist(previousMessages.length - 12)
        : previousMessages;

    final List<MessageEntity> workingHistory = [...recentHistory, userMessage];

    // =======================================================================
    // هنعمل هنناااا ال loop tool call
    // =======================================================================

    bool thereIsTool = false;
    int loopCount = 0;
    int usedTokenOllama = 0;
    String lastAssistantContent = '';
    final Set<String> validExerciseCandidates = {};
    final Set<String> validMealCandidates = {};

    while (loopCount < maxToolLoops) {
      loopCount++;
      final responseResult = await _chatRepository
          .requestCoachResponseWithTools(
            conversationHistory: workingHistory,
            muscleGroups: filterMetadata.muscleGroups,
            difficulties: filterMetadata.difficulties,
            equipment: filterMetadata.equipments,
            mealCategories: filterMetadata.mealCategories,
            mealAreas: filterMetadata.mealAreas,
          );

      final response = switch (responseResult) {
        Success(data: final data) => data,
        Error(failure: final failure) => throw failure,
      };

      usedTokenOllama += response.totalTokensUsed;
      lastAssistantContent = response.content;

      workingHistory.add(
        MessageEntity(
          id: '',
          chatId: activeChatId,
          content: response.content,
          role: 'assistant',
          createdAt: DateTime.now(),
          toolCalls: response.toolCalls,
        ),
      );

      if (!response.hasToolCalls) {
        break;
      }
      thereIsTool = true;

      // =====================================================================
      //هنا هننده عل ى الداتا بيز من شغل علي
      // =====================================================================
      for (final ToolCallEntity call in response.toolCalls) {
        final Map<String, dynamic> args = call.arguments;

        if (call.name == 'get_exercises') {
          // 1. نبحث في exercises.db عن طريق CatalogRepository
          final exercises = await _catalogRepository.getExercisesForTool(
            muscleGroup: args['muscle_group']?.toString(),
            difficulty: args['difficulty']?.toString(),
            equipment: args['equipment']?.toString(),
          );

          // 2. نسجل الـ IDs الحقيقية ونجهز JSON خفيف يفهمه الموديل
          final rowsJson = exercises.map((e) {
            validExerciseCandidates.add(e.id);
            return {
              'id': e.id,
              'name': e.exercise,
              'name_ar': e.nameAr,
              'muscle_group': e.targetMuscleGroup,
              'difficulty': e.difficultyLevel,
              'equipment': e.primaryEquipment,
            };
          }).toList();

          workingHistory.add(
            MessageEntity(
              id: '',
              chatId: activeChatId,
              role: 'tool',
              toolName: call.name,
              toolCallId: call.id,
              content: jsonEncode(rowsJson),
              createdAt: DateTime.now(),
            ),
          );
        } else if (call.name == 'get_meals') {
          final meals = await _catalogRepository.getMealsForTool(
            category: args['category']?.toString(),
            area: args['area']?.toString(),
            minProtein: (args['min_protein'] as num?)?.toDouble(),
            maxKcal: (args['max_kcal'] as num?)?.toDouble(),
            vegetarian: args['vegetarian'] as bool?,
          );

          // 2. نسجل الـ IDs الحقيقية ونجهز JSON خفيف يفهمه الموديل
          final rowsJson = meals.map((m) {
            validMealCandidates.add(m.id);
            return {
              'id': m.id,
              'name': m.name,
              'name_ar': m.nameAr,
              'category': m.category,
              'area': m.area,
              'kcal': m.kcal,
              'protein_g': m.proteinG,
            };
          }).toList();


          // 3. نضيف نتيجة الأداة في workingHistory بدور 'tool'
          workingHistory.add(
            MessageEntity(
              id: '',
              chatId: activeChatId,
              role: 'tool',
              toolName: call.name,
              toolCallId: call.id,
              content: jsonEncode(rowsJson),
              createdAt: DateTime.now(),
            ),
          );
        }
      }
    }


    //answer schemaa
    String finalAnswerText = '';
    List<String> chosenExerciseIds = [];
    List<String> chosenMealIds = [];

    if (!thereIsTool) {
      finalAnswerText = lastAssistantContent;
    } else {
      // لو استخدم أداة، نطلب من أولاما تحويل الرد إلى JSON مطابق للـ answerSchema
      final structuredResult = await _chatRepository
          .requestStructuredCoachResponse(
            conversationHistory: [
              ...workingHistory,
              MessageEntity(
                id: '',
                chatId: activeChatId,
                role: 'user',
                content:
                    'Convert your previous answer to JSON matching the schema.',
                createdAt: DateTime.now(),
              ),
            ],
          );

      final structuredResponse = switch (structuredResult) {
        Success(data: final data) => data,
        Error(failure: final failure) => throw failure,
      };

      // نضيف الـ Tokens المستهلكة في خطوة الـ Formatting إلى حصالة هذا الدور
      usedTokenOllama += structuredResponse.totalTokensUsed;

      // نفك الـ JSON الراجع من الموديل
      final parsed =
          jsonDecode(structuredResponse.content) as Map<String, dynamic>;
      finalAnswerText = parsed['answer'] as String? ?? lastAssistantContent;

      // نفلتر الـ IDs ضد القوائم الحقيقية لضمان عدم وجود أي ID مخترع
      chosenExerciseIds = ((parsed['exercise_ids'] as List?) ?? const [])
          .map((e) => e.toString())
          .where(validExerciseCandidates.contains)
          .toList();

      chosenMealIds = ((parsed['meal_ids'] as List?) ?? const [])
          .map((e) => e.toString())
          .where(validMealCandidates.contains)
          .toList();
    }

    // جلب الكيانات الكاملة (بالصور واليوتيوب والمكونات) من SQLite لعرض الكروت
    final List<ExerciseEntity> exercises = await _catalogRepository
        .getExercisesByIds(chosenExerciseIds);
    final List<MealEntity> meals = await _catalogRepository.getMealsByIds(
      chosenMealIds,
    );

    // =======================================================================
    // الخطوة 6: حفظ رد الـ Assistant في Firestore وإرجاع النتيجة للـ Cubit
    // =======================================================================

    final saveAssistantResult = await _chatRepository.saveMessage(
      message: MessageEntity(
        id: '',
        chatId: activeChatId,
        role: 'assistant',
        content: finalAnswerText,
        exerciseIds: chosenExerciseIds,
        mealIds: chosenMealIds,
        tokensUsed: usedTokenOllama,
        createdAt: DateTime.now(),
      ),
    );
    if (saveAssistantResult case Error(failure: final failure)) {
      return Error(failure);
    }

    final int updatedTotalTokens = sumOfTokens + usedTokenOllama;

    return Success(
      ChatOutput(
        chatId: activeChatId,
        answerText: finalAnswerText,
        exercises: exercises,
        meals: meals,
        totalTokensUsed: updatedTotalTokens,
        isNearTokenLimit: updatedTotalTokens >= (maxSessionTokens * 0.85),
      ),
    );
  }
}
